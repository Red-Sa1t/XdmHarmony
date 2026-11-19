// SPDX-License-Identifier: GPL-2.0-or-later
#include "MediaProcessor.h"

#include <utility>

namespace xdm::media {

JobState::JobState(std::string value, const void* jobOwner) : id(std::move(value)), owner(jobOwner) {}

bool JobState::RequestCancel() noexcept
{
    auto expected = JobLifecycle::Running;
    return lifecycle_.compare_exchange_strong(expected, JobLifecycle::CancelRequested);
}

bool JobState::IsCancelled() const noexcept
{
    return lifecycle_.load() == JobLifecycle::CancelRequested;
}

bool JobState::TryCommit() noexcept
{
    auto expected = JobLifecycle::Running;
    return lifecycle_.compare_exchange_strong(expected, JobLifecycle::Committed);
}

void JobState::FinishFailure() noexcept
{
    auto expected = JobLifecycle::Running;
    lifecycle_.compare_exchange_strong(expected, JobLifecycle::Finished);
}

void JobState::AdvanceTime(int64_t value) noexcept
{
    int64_t previous = processedTimeMs.load();
    while (value > previous && !processedTimeMs.compare_exchange_weak(previous, value)) {}
}

std::shared_ptr<JobState> JobRegistry::Acquire(const std::string& id, const void* owner)
{
    std::lock_guard<std::mutex> lock(mutex_);
    if (active_) { return nullptr; }
    active_ = std::make_shared<JobState>(id, owner);
    return active_;
}

std::shared_ptr<JobState> JobRegistry::Find(const std::string& id, const void* owner)
{
    std::lock_guard<std::mutex> lock(mutex_);
    return active_ && active_->id == id && active_->owner == owner ? active_ : nullptr;
}

bool JobRegistry::Cancel(const std::string& id, const void* owner)
{
    auto job = Find(id, owner);
    return job && job->RequestCancel();
}

void JobRegistry::CancelOwner(const void* owner)
{
    std::shared_ptr<JobState> job;
    {
        std::lock_guard<std::mutex> lock(mutex_);
        if (active_ && active_->owner == owner) { job = active_; }
    }
    if (job) { job->RequestCancel(); }
}

void JobRegistry::Release(const std::shared_ptr<JobState>& job)
{
    std::lock_guard<std::mutex> lock(mutex_);
    if (active_ == job) { active_.reset(); }
}

const char* PhaseName(Phase phase) noexcept
{
    switch (phase) {
        case Phase::Validate: return "validate";
        case Phase::Open: return "open";
        case Phase::Read: return "read";
        case Phase::Decode: return "decode";
        case Phase::Resample: return "resample";
        case Phase::Encode: return "encode";
        case Phase::Mux: return "mux";
        case Phase::Close: return "close";
    }
    return "validate";
}

const char* StatusName(Status status) noexcept
{
    switch (status) {
        case Status::Success: return "success";
        case Status::Failed: return "failed";
        case Status::Cancelled: return "cancelled";
        case Status::Busy: return "busy";
    }
    return "failed";
}

const char* ErrorName(ErrorCode code) noexcept
{
    switch (code) {
        case ErrorCode::None: return "NONE";
        case ErrorCode::InvalidArgument: return "INVALID_ARGUMENT";
        case ErrorCode::InputNotFound: return "INPUT_NOT_FOUND";
        case ErrorCode::InputIo: return "INPUT_IO";
        case ErrorCode::UnsupportedStream: return "UNSUPPORTED_STREAM";
        case ErrorCode::CodecUnavailable: return "CODEC_UNAVAILABLE";
        case ErrorCode::OutputExists: return "OUTPUT_EXISTS";
        case ErrorCode::OutputIo: return "OUTPUT_IO";
        case ErrorCode::InvalidData: return "INVALID_DATA";
        case ErrorCode::ResourceLimit: return "RESOURCE_LIMIT";
        case ErrorCode::Internal: return "INTERNAL";
        case ErrorCode::Cancelled: return "CANCELLED";
        case ErrorCode::Busy: return "BUSY";
    }
    return "INTERNAL";
}

bool ValidJobId(const std::string& id) noexcept
{
    if (id.empty() || id.size() > 128) { return false; }
    for (unsigned char ch : id) {
        if (!((ch >= 'a' && ch <= 'z') || (ch >= 'A' && ch <= 'Z') ||
              (ch >= '0' && ch <= '9') || ch == '-' || ch == '_' || ch == '.' || ch == ':')) {
            return false;
        }
    }
    return true;
}

bool ValidAbsolutePath(const std::string& path) noexcept
{
    return path.size() > 1 && path.size() < 4096 && path[0] == '/' &&
           path.find('\0') == std::string::npos;
}

} // namespace xdm::media
