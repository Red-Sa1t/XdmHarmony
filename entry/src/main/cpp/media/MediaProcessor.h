// SPDX-License-Identifier: GPL-2.0-or-later
#ifndef XDM_MEDIA_PROCESSOR_H
#define XDM_MEDIA_PROCESSOR_H

#include <atomic>
#include <cstdint>
#include <memory>
#include <mutex>
#include <string>
#include <vector>

namespace xdm::media {

enum class Phase { Validate, Open, Read, Decode, Resample, Encode, Mux, Close };
enum class Status { Success, Failed, Cancelled, Busy };
enum class ErrorCode {
    None, InvalidArgument, InputNotFound, InputIo, UnsupportedStream, CodecUnavailable,
    OutputExists, OutputIo, InvalidData, ResourceLimit, Internal, Cancelled, Busy
};
enum class Operation { Remux, ToMp3 };
enum class JobLifecycle { Running, CancelRequested, Committed, Finished };

struct Request {
    Operation operation = Operation::Remux;
    std::string jobId;
    std::string inputVideo;
    std::string inputAudio;
    std::string temporaryOutput;
    std::string container;
};

struct Result {
    Status status = Status::Failed;
    ErrorCode errorCode = ErrorCode::Internal;
    int nativeCode = 0;
    Phase phase = Phase::Validate;
    std::string jobId;
    // Populated only after the exclusive temporary file is fully closed and committed.
    std::string outputPath;
    std::string format;
    int64_t outputBytes = 0;
    int64_t durationMs = -1;
    std::vector<std::string> warnings;
};

struct Capabilities {
    std::string ffmpegVersion;
    std::string lameVersion;
    std::string abi;
    bool remuxMp4 = false;
    bool remuxMatroska = false;
    bool encodeMp3 = false;
};

// No napi_value, environment pointer dereference, or UI callback is permitted here.
class JobState final {
public:
    explicit JobState(std::string id, const void* owner = nullptr);
    const std::string id;
    const void* const owner;
    std::atomic<Phase> phase { Phase::Validate };
    std::atomic<int64_t> processedTimeMs { 0 };
    std::atomic<int64_t> totalTimeMs { -1 };

    bool RequestCancel() noexcept;
    bool IsCancelled() const noexcept;
    // Linearization point: a successful cancel and a successful commit are exclusive.
    bool TryCommit() noexcept;
    void FinishFailure() noexcept;
    void AdvanceTime(int64_t value) noexcept;

private:
    std::atomic<JobLifecycle> lifecycle_ { JobLifecycle::Running };
};

// One native operation process-wide, including operations from separate ArkTS workers.
// All locks are short; none is held during file IO, FFmpeg calls, or JS callbacks.
class JobRegistry final {
public:
    std::shared_ptr<JobState> Acquire(const std::string& id, const void* owner);
    std::shared_ptr<JobState> Find(const std::string& id, const void* owner);
    bool Cancel(const std::string& id, const void* owner);
    void CancelOwner(const void* owner);
    void Release(const std::shared_ptr<JobState>& job);

private:
    std::mutex mutex_;
    std::shared_ptr<JobState> active_;
};

const char* PhaseName(Phase phase) noexcept;
const char* StatusName(Status status) noexcept;
const char* ErrorName(ErrorCode code) noexcept;
bool ValidJobId(const std::string& id) noexcept;
bool ValidAbsolutePath(const std::string& path) noexcept;
Capabilities GetCapabilities();
Result Process(const Request& request, JobState& job) noexcept;

} // namespace xdm::media
#endif
