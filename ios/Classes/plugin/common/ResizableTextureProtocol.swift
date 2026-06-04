#if canImport(Flutter)
  import Flutter
#elseif canImport(FlutterMacOS)
  import FlutterMacOS
#endif

public protocol ResizableTextureProtocol: NSObject, FlutterTexture {
  func resize(_ size: CGSize)
  func render(_ size: CGSize)
  // PiP : appelé pour chaque frame rendue (une copie est poussée vers
  // l'AVSampleBufferDisplayLayer). nil tant que le PiP n'est pas attaché.
  var onFrameRendered: ((CVPixelBuffer) -> Void)? { get set }
}
