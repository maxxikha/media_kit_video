#if canImport(Flutter)
  import AVFoundation
  import AVKit
  import CoreMedia
  import Flutter
  import UIKit

  /// Bridges `AVPictureInPictureController` with a `media_kit_video`
  /// `VideoOutput` frame source. Requires iOS 15+ to compile-guard access to
  /// `AVSampleBufferDisplayLayer`-based PiP APIs.
  @available(iOS 15.0, *)
  final class MediaKitPictureInPictureController: NSObject {
    typealias EventCallback = ([String: Any]) -> Void

    private let hostView: UIView
    private let outputManager: VideoOutputManager
    private let eventCallback: EventCallback
    private let displayLayer: AVSampleBufferDisplayLayer
    private var pipController: AVPictureInPictureController?
    private let enqueueQueue = DispatchQueue(
      label: "com.alexmercerind.media_kit_video.pip.enqueue",
      qos: .userInteractive
    )

    private var handle: Int64?
    private var isPlayingState: Bool = true
    private var startRequested: Bool = false
    private var firstFrameEnqueued: Bool = false
    private var startAttempts: Int = 0
    private var didRestoreInterface: Bool = false

    init(
      hostView: UIView,
      outputManager: VideoOutputManager,
      videoSize: CGSize,
      eventCallback: @escaping EventCallback
    ) {
      self.hostView = hostView
      self.outputManager = outputManager
      self.eventCallback = eventCallback
      self.displayLayer = AVSampleBufferDisplayLayer()
      super.init()

      displayLayer.videoGravity = .resizeAspect
      displayLayer.frame = CGRect(x: 0, y: 0, width: 2, height: 2)
      displayLayer.isOpaque = false
      displayLayer.backgroundColor = UIColor.clear.cgColor
      hostView.layer.insertSublayer(displayLayer, at: 0)

      NotificationCenter.default.addObserver(
        self,
        selector: #selector(appDidBecomeActive),
        name: UIApplication.didBecomeActiveNotification,
        object: nil
      )
    }

    deinit {
      NotificationCenter.default.removeObserver(self)
      teardown()
    }

    @objc private func appDidBecomeActive() {
      guard let controller = pipController,
        controller.isPictureInPictureActive
      else { return }
      DispatchQueue.main.async {
        controller.stopPictureInPicture()
      }
    }

    var isActive: Bool {
      return pipController?.isPictureInPictureActive ?? false
    }

    @discardableResult
    func start(
      handle: Int64,
      autoEnter: Bool,
      startImmediately: Bool
    ) -> Bool {
      self.handle = handle

      let contentSource = AVPictureInPictureController.ContentSource(
        sampleBufferDisplayLayer: displayLayer,
        playbackDelegate: self
      )
      let controller = AVPictureInPictureController(contentSource: contentSource)
      controller.delegate = self
      controller.canStartPictureInPictureAutomaticallyFromInline = autoEnter
      self.pipController = controller

      outputManager.setOnFrameRendered(handle: handle) { [weak self] pixelBuffer in
        self?.enqueue(pixelBuffer: pixelBuffer)
      }

      self.startRequested = startImmediately
      self.firstFrameEnqueued = false
      self.startAttempts = 0
      return true
    }

    private func attemptStart() {
      guard let controller = pipController else { return }
      if controller.isPictureInPictureActive { return }
      if controller.isPictureInPicturePossible {
        controller.startPictureInPicture()
        return
      }
      startAttempts += 1
      if startAttempts >= 20 {
        eventCallback(["event": "failed", "reason": "pip_not_possible"])
        return
      }
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
        self?.attemptStart()
      }
    }

    func stop() {
      if let controller = pipController, controller.isPictureInPictureActive {
        DispatchQueue.main.async { controller.stopPictureInPicture() }
      }
      teardown()
    }

    func setAutoEnter(_ enabled: Bool) {
      pipController?.canStartPictureInPictureAutomaticallyFromInline = enabled
    }

    private func teardown() {
      if let handle = handle {
        outputManager.setOnFrameRendered(handle: handle, nil)
        self.handle = nil
      }
      pipController = nil
      displayLayer.flushAndRemoveImage()
      displayLayer.removeFromSuperlayer()
    }

    private func enqueue(pixelBuffer: CVPixelBuffer) {
      // CRITICAL (IPTVIA fix — fixes iOS playback freeze):
      // The incoming pixel buffer belongs to the renderer's recycling pool
      // (`textureContexts`). If we hand it straight to
      // CMSampleBufferCreateReadyWithImageBuffer + AVSampleBufferDisplayLayer it
      // stays *retained* inside the display layer's queue, the render pool can
      // no longer recycle that slot, libmpv's render worker blocks waiting for a
      // free buffer, and the on-screen video freezes (infinite spinner, inert
      // play button). Deep-copy into an independently-owned buffer *synchronously*
      // (on the render thread, before dispatching) so the pool buffer is released
      // the instant this returns and the renderer keeps flowing.
      guard
        let copy = MediaKitPictureInPictureController.copyPixelBuffer(pixelBuffer)
      else { return }
      enqueueQueue.async { [weak self] in
        guard let self = self else { return }
        guard self.displayLayer.isReadyForMoreMediaData else { return }
        guard let sample = self.makeSampleBuffer(from: copy) else { return }
        self.displayLayer.enqueue(sample)
        if !self.firstFrameEnqueued {
          self.firstFrameEnqueued = true
          if self.startRequested {
            DispatchQueue.main.async { [weak self] in
              self?.attemptStart()
            }
          }
        }
      }
    }

    /// Deep-copies a CVPixelBuffer into a fresh, independently-owned buffer so
    /// the source (renderer pool) buffer can be recycled immediately. Handles
    /// both packed (e.g. BGRA) and planar (e.g. NV12 / YUV) layouts.
    private static func copyPixelBuffer(_ src: CVPixelBuffer) -> CVPixelBuffer? {
      let width = CVPixelBufferGetWidth(src)
      let height = CVPixelBufferGetHeight(src)
      let pixelFormat = CVPixelBufferGetPixelFormatType(src)

      let attrs: [CFString: Any] = [
        kCVPixelBufferIOSurfacePropertiesKey: [CFString: Any]() as CFDictionary,
        kCVPixelBufferMetalCompatibilityKey: true,
      ]

      var dst: CVPixelBuffer?
      let createStatus = CVPixelBufferCreate(
        kCFAllocatorDefault,
        width,
        height,
        pixelFormat,
        attrs as CFDictionary,
        &dst
      )
      guard createStatus == kCVReturnSuccess, let dest = dst else { return nil }

      CVPixelBufferLockBaseAddress(src, .readOnly)
      CVPixelBufferLockBaseAddress(dest, [])
      defer {
        CVPixelBufferUnlockBaseAddress(dest, [])
        CVPixelBufferUnlockBaseAddress(src, .readOnly)
      }

      if CVPixelBufferIsPlanar(src) {
        let planeCount = CVPixelBufferGetPlaneCount(src)
        for plane in 0..<planeCount {
          guard
            let srcBase = CVPixelBufferGetBaseAddressOfPlane(src, plane),
            let dstBase = CVPixelBufferGetBaseAddressOfPlane(dest, plane)
          else { continue }
          let srcStride = CVPixelBufferGetBytesPerRowOfPlane(src, plane)
          let dstStride = CVPixelBufferGetBytesPerRowOfPlane(dest, plane)
          let planeHeight = CVPixelBufferGetHeightOfPlane(src, plane)
          if srcStride == dstStride {
            memcpy(dstBase, srcBase, srcStride * planeHeight)
          } else {
            let bytes = min(srcStride, dstStride)
            for row in 0..<planeHeight {
              memcpy(
                dstBase.advanced(by: row * dstStride),
                srcBase.advanced(by: row * srcStride),
                bytes
              )
            }
          }
        }
      } else {
        guard
          let srcBase = CVPixelBufferGetBaseAddress(src),
          let dstBase = CVPixelBufferGetBaseAddress(dest)
        else { return nil }
        let srcStride = CVPixelBufferGetBytesPerRow(src)
        let dstStride = CVPixelBufferGetBytesPerRow(dest)
        if srcStride == dstStride {
          memcpy(dstBase, srcBase, srcStride * height)
        } else {
          let bytes = min(srcStride, dstStride)
          for row in 0..<height {
            memcpy(
              dstBase.advanced(by: row * dstStride),
              srcBase.advanced(by: row * srcStride),
              bytes
            )
          }
        }
      }
      return dest
    }

    private func makeSampleBuffer(from pixelBuffer: CVPixelBuffer) -> CMSampleBuffer? {
      var formatDescription: CMVideoFormatDescription?
      let fdStatus = CMVideoFormatDescriptionCreateForImageBuffer(
        allocator: kCFAllocatorDefault,
        imageBuffer: pixelBuffer,
        formatDescriptionOut: &formatDescription
      )
      guard fdStatus == noErr, let description = formatDescription else { return nil }

      let presentationTime = CMClockGetTime(CMClockGetHostTimeClock())
      var timingInfo = CMSampleTimingInfo(
        duration: .invalid,
        presentationTimeStamp: presentationTime,
        decodeTimeStamp: .invalid
      )

      var sampleBuffer: CMSampleBuffer?
      let status = CMSampleBufferCreateReadyWithImageBuffer(
        allocator: kCFAllocatorDefault,
        imageBuffer: pixelBuffer,
        formatDescription: description,
        sampleTiming: &timingInfo,
        sampleBufferOut: &sampleBuffer
      )
      guard status == noErr, let buffer = sampleBuffer else { return nil }

      if let attachments = CMSampleBufferGetSampleAttachmentsArray(
        buffer,
        createIfNecessary: true
      ) as? [NSMutableDictionary],
        let first = attachments.first
      {
        first[kCMSampleAttachmentKey_DisplayImmediately as NSString] = kCFBooleanTrue
      }
      return buffer
    }
  }

  @available(iOS 15.0, *)
  extension MediaKitPictureInPictureController: AVPictureInPictureControllerDelegate {
    func pictureInPictureControllerWillStartPictureInPicture(
      _ controller: AVPictureInPictureController
    ) {
      eventCallback(["event": "willStart"])
    }

    func pictureInPictureControllerDidStartPictureInPicture(
      _ controller: AVPictureInPictureController
    ) {
      eventCallback(["event": "didStart"])
    }

    func pictureInPictureController(
      _ controller: AVPictureInPictureController,
      failedToStartPictureInPictureWithError error: Error
    ) {
      eventCallback(["event": "failed", "reason": error.localizedDescription])
    }

    func pictureInPictureControllerWillStopPictureInPicture(
      _ controller: AVPictureInPictureController
    ) {
      didRestoreInterface = false
      eventCallback(["event": "willStop"])
    }

    func pictureInPictureControllerDidStopPictureInPicture(
      _ controller: AVPictureInPictureController
    ) {
      if didRestoreInterface {
        eventCallback(["event": "didStop"])
      } else {
        eventCallback(["event": "closed"])
      }
      didRestoreInterface = false
    }

    func pictureInPictureController(
      _ controller: AVPictureInPictureController,
      restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completionHandler:
        @escaping (Bool) -> Void
    ) {
      didRestoreInterface = true
      eventCallback(["event": "restore"])
      completionHandler(true)
    }
  }

  @available(iOS 15.0, *)
  extension MediaKitPictureInPictureController: AVPictureInPictureSampleBufferPlaybackDelegate {
    func pictureInPictureController(
      _ pipController: AVPictureInPictureController,
      setPlaying playing: Bool
    ) {
      isPlayingState = playing
      eventCallback(["event": "setPlaying", "playing": playing])
    }

    // Le handle mpv reel est deja disponible ici (meme Int64 que celui
    // stocke par VideoOutput, caste de facon identique). Sans duree
    // connue (direct, ou handle/lecture indisponible pour n'importe
    // quelle raison), on CONSERVE EXACTEMENT le comportement d'origine -
    // le direct n'est JAMAIS affecte par ce changement.
    func pictureInPictureControllerTimeRangeForPlayback(
      _ pipController: AVPictureInPictureController
    ) -> CMTimeRange {
      guard
        let handle = self.handle,
        let mpvHandle = OpaquePointer(bitPattern: Int(handle))
      else {
        return CMTimeRange(start: .negativeInfinity, duration: .positiveInfinity)
      }
      let duration = MPVHelpers.getDuration(mpvHandle)
      guard duration > 0 else {
        // live/duree inconnue - comportement direct preserve
        return CMTimeRange(start: .negativeInfinity, duration: .positiveInfinity)
      }
      return CMTimeRange(
        start: .zero,
        duration: CMTime(seconds: duration, preferredTimescale: 600)
      )
    }

    func pictureInPictureControllerIsPlaybackPaused(
      _ pipController: AVPictureInPictureController
    ) -> Bool {
      return !isPlayingState
    }

    func pictureInPictureController(
      _ pipController: AVPictureInPictureController,
      didTransitionToRenderSize newRenderSize: CMVideoDimensions
    ) {
    }

    // Seek reel via le meme handle mpv que ci-dessus. completionHandler()
    // toujours appele en dernier, comme avant (contrat AVKit respecte a
    // l'identique).
    func pictureInPictureController(
      _ pipController: AVPictureInPictureController,
      skipByInterval skipInterval: CMTime,
      completion completionHandler: @escaping () -> Void
    ) {
      if let handle = self.handle,
        let mpvHandle = OpaquePointer(bitPattern: Int(handle))
      {
        let seconds = CMTimeGetSeconds(skipInterval)
        if seconds.isFinite {
          MPVHelpers.seekRelative(mpvHandle, seconds: seconds)
        }
      }
      completionHandler()
    }
  }
#endif
