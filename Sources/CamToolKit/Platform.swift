// CamTool only targets macOS on Apple Silicon: any other platform
// (Intel Mac, Linux, Windows) is rejected at build time.
#if !(os(macOS) && arch(arm64))
#error("CamTool only runs on macOS with Apple Silicon (arm64).")
#endif
