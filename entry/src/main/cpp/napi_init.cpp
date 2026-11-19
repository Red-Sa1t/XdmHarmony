// SPDX-License-Identifier: GPL-2.0-or-later
#ifdef XDM_HOST_NAPI_TEST
#include <node_api.h>
#else
#include <napi/native_api.h>
#endif

#include "media/MediaProcessor.h"

#include <cerrno>
#include <memory>
#include <new>
#include <thread>
#include <utility>

namespace {
using namespace xdm::media;

JobRegistry registry;

struct Bindings;
struct Environment {
    napi_env env = nullptr;
    napi_async_cleanup_hook_handle cleanup = nullptr;
    Bindings* bindings = nullptr;
    bool closing = false;
    bool cleanupInvoked = false;
    size_t inFlight = 0;
};

struct Bindings { std::shared_ptr<Environment> state; };

struct Work {
    std::shared_ptr<Environment> state;
    std::shared_ptr<JobState> job;
    Request request;
    Result result;
    napi_deferred deferred = nullptr;
    napi_threadsafe_function completion = nullptr;
    std::thread thread;
    bool counted = false;
    bool delivered = false;

    ~Work()
    {
        registry.Release(job);
        if (counted) { --state->inFlight; }
    }
};

struct NapiFailure {};

void Require(napi_status status)
{
    if (status != napi_ok) { throw NapiFailure {}; }
}

napi_value String(napi_env env, const char* value)
{
    napi_value result = nullptr;
    Require(napi_create_string_utf8(env, value, NAPI_AUTO_LENGTH, &result));
    return result;
}

napi_value String(napi_env env, const std::string& value)
{
    napi_value result = nullptr;
    Require(napi_create_string_utf8(env, value.data(), value.size(), &result));
    return result;
}

void Set(napi_env env, napi_value object, const char* name, napi_value value)
{
    Require(napi_set_named_property(env, object, name, value));
}

void SetString(napi_env env, napi_value object, const char* name, const std::string& value)
{
    Set(env, object, name, String(env, value));
}

void SetBoolean(napi_env env, napi_value object, const char* name, bool value)
{
    napi_value result = nullptr;
    Require(napi_get_boolean(env, value, &result));
    Set(env, object, name, result);
}

void SetNumber(napi_env env, napi_value object, const char* name, int64_t value)
{
    napi_value result = nullptr;
    Require(napi_create_int64(env, value, &result));
    Set(env, object, name, result);
}

napi_value ResultValue(napi_env env, const Result& result)
{
    napi_value object = nullptr;
    Require(napi_create_object(env, &object));
    Set(env, object, "status", String(env, StatusName(result.status)));
    Set(env, object, "errorCode", String(env, ErrorName(result.errorCode)));
    Set(env, object, "phase", String(env, PhaseName(result.phase)));
    SetNumber(env, object, "nativeCode", result.nativeCode);
    SetString(env, object, "jobId", result.jobId);
    SetString(env, object, "outputPath", result.outputPath);
    SetString(env, object, "format", result.format);
    SetNumber(env, object, "outputBytes", result.outputBytes);
    SetNumber(env, object, "durationMs", result.durationMs);
    napi_value warnings = nullptr;
    Require(napi_create_array_with_length(env, result.warnings.size(), &warnings));
    for (uint32_t i = 0; i < result.warnings.size(); ++i) {
        Require(napi_set_element(env, warnings, i, String(env, result.warnings[i])));
    }
    Set(env, object, "warnings", warnings);
    return object;
}

void ThrowInternal(napi_env env) noexcept
{
    bool pending = false;
    napi_is_exception_pending(env, &pending);
    if (!pending) { napi_throw_error(env, "XDM_MEDIA_INTERNAL", "Native media bridge initialization failed"); }
}

void RejectInternal(napi_env env, napi_deferred deferred) noexcept
{
    napi_value message = nullptr;
    napi_value error = nullptr;
    if (napi_create_string_utf8(env, "Native media bridge result allocation failed", NAPI_AUTO_LENGTH, &message) == napi_ok &&
        napi_create_error(env, nullptr, message, &error) == napi_ok) {
        napi_reject_deferred(env, deferred, error);
    }
}

Bindings* Arguments(napi_env env, napi_callback_info info, size_t expected, napi_value (&values)[6])
{
    size_t argc = 6;
    void* data = nullptr;
    Require(napi_get_cb_info(env, info, &argc, values, nullptr, &data));
    if (argc != expected || data == nullptr) {
        napi_throw_type_error(env, "XDM_MEDIA_ARGUMENT", "Unexpected native media argument count");
        throw NapiFailure {};
    }
    return static_cast<Bindings*>(data);
}

std::string ReadString(napi_env env, napi_value value)
{
    napi_valuetype type = napi_undefined;
    Require(napi_typeof(env, value, &type));
    size_t size = 0;
    if (type != napi_string) {
        napi_throw_type_error(env, "XDM_MEDIA_ARGUMENT", "Native media arguments must be strings");
        throw NapiFailure {};
    }
    Require(napi_get_value_string_utf8(env, value, nullptr, 0, &size));
    if (size >= 4096) {
        napi_throw_type_error(env, "XDM_MEDIA_ARGUMENT", "Native media argument is too long");
        throw NapiFailure {};
    }
    std::string result(size + 1, '\0');
    size_t written = 0;
    Require(napi_get_value_string_utf8(env, value, result.data(), result.size(), &written));
    result.resize(written);
    return result;
}

// There is no napi_async_work/UV work request to drain before this hook runs.
// It can cancel the independent native thread promptly, then keeps env alive
// until the TSFN finalizer has joined that thread and released its resources.
void FinishCleanup(const std::shared_ptr<Environment>& state)
{
    if (!state->cleanupInvoked || state->inFlight != 0 || state->cleanup == nullptr) { return; }
    napi_async_cleanup_hook_handle handle = state->cleanup;
    state->cleanup = nullptr;
    Bindings* bindings = state->bindings;
    state->bindings = nullptr;
    napi_remove_async_cleanup_hook(handle);
    delete bindings;
}

void Cleanup(napi_async_cleanup_hook_handle handle, void* data)
{
    auto* bindings = static_cast<Bindings*>(data);
    std::shared_ptr<Environment> state = bindings->state;
    state->closing = true;
    state->cleanupInvoked = true;
    state->cleanup = handle;
    registry.CancelOwner(state.get());
    FinishCleanup(state);
}

void DeliverResult(napi_env env, Work& work)
{
    if (work.delivered || work.state->closing || env == nullptr) { return; }
    work.delivered = true;
    registry.Release(work.job);
    try { Require(napi_resolve_deferred(env, work.deferred, ResultValue(env, work.result))); }
    catch (...) { RejectInternal(env, work.deferred); }
}

void CompletionCallback(napi_env env, napi_value, void* context, void*)
{
    // An aborted TSFN may call us with env=nullptr only to drain queued data.
    DeliverResult(env, *static_cast<Work*>(context));
}

void FinalizeWork(napi_env env, void* data, void*)
{
    std::unique_ptr<Work> work(static_cast<Work*>(data));
    std::shared_ptr<Environment> state = work->state;
    // TSFN finalizers execute on the environment thread after the worker has
    // released its TSFN reference. Join also establishes result visibility.
    if (work->thread.joinable()) { work->thread.join(); }
    registry.Release(work->job);
    // Even a non-closing completion-enqueue failure must settle its promise.
    DeliverResult(env, *work);
    work.reset();
    // After this call, only ordinary C++ objects may be touched: env teardown can finish.
    FinishCleanup(state);
}

void NotifyCompletion(Work* work)
{
    // Exactly one completion notification, so the bounded queue cannot grow with
    // duration or packet count. Cancellation/progress use JobState atomics.
    napi_threadsafe_function completion = work->completion;
    napi_status status = napi_call_threadsafe_function(completion, nullptr, napi_tsfn_nonblocking);
    // napi_closing already releases the calling thread's reference. The handle
    // must never be touched again, including a second release, in that branch.
    if (status != napi_closing) { napi_release_threadsafe_function(completion, napi_tsfn_release); }
    // No Work access after release: FinalizeWork may now run on the environment thread.
}

void Execute(Work* work)
{
    work->result = Process(work->request, *work->job);
    NotifyCompletion(work);
}

bool ValidRequest(const Request& request)
{
    return ValidJobId(request.jobId) && ValidAbsolutePath(request.inputAudio) &&
        ValidAbsolutePath(request.temporaryOutput) && request.temporaryOutput != request.inputAudio &&
        (request.operation == Operation::ToMp3 ||
         (ValidAbsolutePath(request.inputVideo) && request.temporaryOutput != request.inputVideo &&
          (request.container == "mp4" || request.container == "matroska")));
}

napi_value Submit(napi_env env, Bindings& bindings, Request request)
{
    napi_value promise = nullptr;
    napi_deferred deferred = nullptr;
    Require(napi_create_promise(env, &deferred, &promise));
    Result failure;
    failure.jobId = request.jobId;
    failure.format = request.operation == Operation::ToMp3 ? "mp3" : request.container;
    if (!ValidRequest(request) || bindings.state->closing) {
        failure.errorCode = ErrorCode::InvalidArgument;
        failure.nativeCode = -EINVAL;
        Require(napi_resolve_deferred(env, deferred, ResultValue(env, failure)));
        return promise;
    }
    auto work = std::make_unique<Work>();
    work->state = bindings.state;
    work->job = registry.Acquire(request.jobId, work->state.get());
    if (!work->job) {
        failure.status = Status::Busy;
        failure.errorCode = ErrorCode::Busy;
        failure.nativeCode = -EBUSY;
        Require(napi_resolve_deferred(env, deferred, ResultValue(env, failure)));
        return promise;
    }
    work->request = std::move(request);
    work->deferred = deferred;
    napi_value name = String(env, "XdmMedia");
    napi_status created = napi_create_threadsafe_function(env, nullptr, nullptr, name,
        1, 1, work.get(), FinalizeWork, work.get(), CompletionCallback, &work->completion);
    if (created != napi_ok) {
        failure.errorCode = ErrorCode::ResourceLimit;
        failure.nativeCode = -ENOMEM;
        Require(napi_resolve_deferred(env, deferred, ResultValue(env, failure)));
        return promise;
    }
    ++work->state->inFlight;
    work->counted = true;
    try {
        work->thread = std::thread(Execute, work.get());
    } catch (...) {
        failure.errorCode = ErrorCode::ResourceLimit;
        failure.nativeCode = -EAGAIN;
        work->job->FinishFailure();
        work->result = std::move(failure);
        // FinalizeWork owns release and settlement even if thread creation fails.
        NotifyCompletion(work.get());
    }
    work.release(); // The TSFN finalizer is the sole owner, including environment teardown.
    return promise;
}

napi_value Remux(napi_env env, napi_callback_info info)
{
    try {
        napi_value args[6] {};
        Bindings* bindings = Arguments(env, info, 5, args);
        Request request;
        request.operation = Operation::Remux;
        request.jobId = ReadString(env, args[0]);
        request.inputVideo = ReadString(env, args[1]);
        request.inputAudio = ReadString(env, args[2]);
        request.temporaryOutput = ReadString(env, args[3]);
        request.container = ReadString(env, args[4]);
        return Submit(env, *bindings, std::move(request));
    } catch (...) { ThrowInternal(env); return nullptr; }
}

napi_value ToMp3(napi_env env, napi_callback_info info)
{
    try {
        napi_value args[6] {};
        Bindings* bindings = Arguments(env, info, 3, args);
        Request request;
        request.operation = Operation::ToMp3;
        request.jobId = ReadString(env, args[0]);
        request.inputAudio = ReadString(env, args[1]);
        request.temporaryOutput = ReadString(env, args[2]);
        request.container = "mp3";
        return Submit(env, *bindings, std::move(request));
    } catch (...) { ThrowInternal(env); return nullptr; }
}

napi_value CapabilitiesCallback(napi_env env, napi_callback_info info)
{
    try {
        napi_value args[6] {};
        Arguments(env, info, 0, args);
        Capabilities capabilities = GetCapabilities();
        napi_value object = nullptr;
        Require(napi_create_object(env, &object));
        SetNumber(env, object, "apiVersion", 1);
        SetString(env, object, "ffmpegVersion", capabilities.ffmpegVersion);
        SetString(env, object, "lameVersion", capabilities.lameVersion);
        SetString(env, object, "abi", capabilities.abi);
        SetBoolean(env, object, "remuxMp4", capabilities.remuxMp4);
        SetBoolean(env, object, "remuxMatroska", capabilities.remuxMatroska);
        SetBoolean(env, object, "encodeMp3", capabilities.encodeMp3);
        SetNumber(env, object, "maxActiveJobs", 1);
        return object;
    } catch (...) { ThrowInternal(env); return nullptr; }
}

napi_value Cancel(napi_env env, napi_callback_info info)
{
    try {
        napi_value args[6] {};
        Bindings* bindings = Arguments(env, info, 1, args);
        std::string id = ReadString(env, args[0]);
        bool cancelled = ValidJobId(id) && registry.Cancel(id, bindings->state.get());
        napi_value result = nullptr;
        Require(napi_get_boolean(env, cancelled, &result));
        return result;
    } catch (...) { ThrowInternal(env); return nullptr; }
}

napi_value Progress(napi_env env, napi_callback_info info)
{
    try {
        napi_value args[6] {};
        Bindings* bindings = Arguments(env, info, 1, args);
        std::string id = ReadString(env, args[0]);
        auto job = registry.Find(id, bindings->state.get());
        napi_value object = nullptr;
        Require(napi_create_object(env, &object));
        SetString(env, object, "jobId", id);
        SetBoolean(env, object, "found", job != nullptr);
        Set(env, object, "phase", String(env, job ? PhaseName(job->phase.load()) : "validate"));
        SetNumber(env, object, "processedTimeMs", job ? job->processedTimeMs.load() : 0);
        SetNumber(env, object, "totalTimeMs", job ? job->totalTimeMs.load() : -1);
        SetBoolean(env, object, "cancelRequested", job && job->IsCancelled());
        return object;
    } catch (...) { ThrowInternal(env); return nullptr; }
}

napi_value Initialize(napi_env env, napi_value exports)
{
    std::unique_ptr<Bindings> bindings;
    try {
        bindings = std::make_unique<Bindings>();
        bindings->state = std::make_shared<Environment>();
        bindings->state->env = env;
        bindings->state->bindings = bindings.get();
        Require(napi_add_async_cleanup_hook(env, Cleanup, bindings.get(), &bindings->state->cleanup));
        napi_property_descriptor descriptors[] {
            { "capabilities", nullptr, CapabilitiesCallback, nullptr, nullptr, nullptr, napi_default, bindings.get() },
            { "remux", nullptr, Remux, nullptr, nullptr, nullptr, napi_default, bindings.get() },
            { "toMp3", nullptr, ToMp3, nullptr, nullptr, nullptr, napi_default, bindings.get() },
            { "cancel", nullptr, Cancel, nullptr, nullptr, nullptr, napi_default, bindings.get() },
            { "progress", nullptr, Progress, nullptr, nullptr, nullptr, napi_default, bindings.get() }
        };
        Require(napi_define_properties(env, exports, sizeof(descriptors) / sizeof(descriptors[0]), descriptors));
        bindings.release();
        return exports;
    } catch (...) {
        if (bindings && bindings->state && bindings->state->cleanup) {
            napi_remove_async_cleanup_hook(bindings->state->cleanup);
        }
        ThrowInternal(env);
        return nullptr;
    }
}

} // namespace

#ifdef XDM_HOST_NAPI_TEST
NAPI_MODULE(xdm_media, Initialize)
#else
static napi_module module {
    1, 0, nullptr, Initialize, "xdm_media", nullptr, { nullptr }
};

extern "C" __attribute__((constructor)) void RegisterXdmMediaModule()
{
    napi_module_register(&module);
}
#endif
