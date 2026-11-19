// SPDX-License-Identifier: GPL-2.0-or-later
// Standalone driver for the same C++ implementation linked into libxdm_media.so.
#include "media/MediaProcessor.h"

#include <atomic>
#include <chrono>
#include <cstdlib>
#include <iostream>
#include <string>
#include <thread>

using namespace xdm::media;

static std::string JsonString(const std::string& value)
{
    const char* hex = "0123456789abcdef";
    std::string escaped = "\"";
    for (unsigned char ch : value) {
        if (ch == '"' || ch == '\\') { escaped.push_back('\\'); escaped.push_back(static_cast<char>(ch)); }
        else if (ch < 0x20) {
            escaped += "\\u00";
            escaped.push_back(hex[ch >> 4]);
            escaped.push_back(hex[ch & 15]);
        } else { escaped.push_back(static_cast<char>(ch)); }
    }
    escaped.push_back('"');
    return escaped;
}

int main(int argc, char** argv)
{
    if (argc == 2 && std::string(argv[1]) == "capabilities") {
        auto capabilities = GetCapabilities();
        std::cout << "{\"ffmpegVersion\":" << JsonString(capabilities.ffmpegVersion)
                  << ",\"lameVersion\":" << JsonString(capabilities.lameVersion)
                  << ",\"abi\":" << JsonString(capabilities.abi)
                  << ",\"remuxMp4\":" << (capabilities.remuxMp4 ? "true" : "false")
                  << ",\"remuxMatroska\":" << (capabilities.remuxMatroska ? "true" : "false")
                  << ",\"encodeMp3\":" << (capabilities.encodeMp3 ? "true" : "false") << "}\n";
        return 0;
    }
    if (argc < 5 || (std::string(argv[1]) != "mp3" && std::string(argv[1]) != "remux")) {
        std::cerr << "Usage: media_runner capabilities | mp3 ID INPUT OUTPUT [--cancel-ms N | --cancel-phase PHASE]\n"
                     "       media_runner remux ID VIDEO AUDIO OUTPUT mp4|matroska [--cancel-ms N | --cancel-phase PHASE]\n";
        return 64;
    }
    Request request;
    request.jobId = argv[2];
    int optionsIndex;
    if (std::string(argv[1]) == "mp3") {
        request.operation = Operation::ToMp3;
        request.inputAudio = argv[3];
        request.temporaryOutput = argv[4];
        request.container = "mp3";
        optionsIndex = 5;
    } else {
        if (argc < 7) { return 64; }
        request.operation = Operation::Remux;
        request.inputVideo = argv[3];
        request.inputAudio = argv[4];
        request.temporaryOutput = argv[5];
        request.container = argv[6];
        optionsIndex = 7;
    }
    int cancelMs = -1;
    std::string cancelPhase;
    if (argc == optionsIndex + 2) {
        std::string option = argv[optionsIndex];
        if (option == "--cancel-ms") { cancelMs = std::atoi(argv[optionsIndex + 1]); }
        else if (option == "--cancel-phase") { cancelPhase = argv[optionsIndex + 1]; }
        else { return 64; }
    } else if (argc != optionsIndex) { return 64; }
    JobState job(request.jobId);
    std::atomic<bool> finished { false };
    bool cancelAccepted = false;
    std::string observedPhase;
    std::thread cancelThread;
    if (cancelMs == 0) { cancelAccepted = job.RequestCancel(); observedPhase = "validate"; }
    else if (cancelMs > 0 || !cancelPhase.empty()) {
        cancelThread = std::thread([&] {
            auto started = std::chrono::steady_clock::now();
            while (!finished.load()) {
                auto elapsed = std::chrono::duration_cast<std::chrono::milliseconds>(std::chrono::steady_clock::now() - started).count();
                Phase phase = job.phase.load();
                if ((cancelMs > 0 && elapsed >= cancelMs) || (!cancelPhase.empty() && cancelPhase == PhaseName(phase))) {
                    observedPhase = PhaseName(phase);
                    cancelAccepted = job.RequestCancel();
                    break;
                }
                if (elapsed > 30000) { break; }
                std::this_thread::yield();
            }
        });
    }
    Result result = Process(request, job);
    finished.store(true);
    if (cancelThread.joinable()) { cancelThread.join(); }
    std::cout << "{\"jobId\":" << JsonString(result.jobId)
              << ",\"status\":" << JsonString(StatusName(result.status))
              << ",\"errorCode\":" << JsonString(ErrorName(result.errorCode))
              << ",\"nativeCode\":" << result.nativeCode
              << ",\"phase\":" << JsonString(PhaseName(result.phase))
              << ",\"outputPath\":" << JsonString(result.outputPath)
              << ",\"format\":" << JsonString(result.format)
              << ",\"outputBytes\":" << result.outputBytes
              << ",\"durationMs\":" << result.durationMs
              << ",\"cancelAccepted\":" << (cancelAccepted ? "true" : "false")
              << ",\"observedCancelPhase\":" << JsonString(observedPhase)
              << ",\"warnings\":[";
    for (size_t i = 0; i < result.warnings.size(); ++i) {
        if (i != 0) { std::cout << ','; }
        std::cout << JsonString(result.warnings[i]);
    }
    std::cout << "]}\n";
    return result.status == Status::Success ? 0 : (result.status == Status::Cancelled ? 3 : 2);
}
