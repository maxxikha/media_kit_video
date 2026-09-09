public enum MPVHelpers {
  public static func checkError(_ status: CInt) {
    if status < 0 {
      NSLog("MPVHelpers: error: \(String(cString: mpv_error_string(status)))")
      exit(1)
    }
  }

  public static func getVideoOutParams(
    _ handle: OpaquePointer
  ) -> MPVVideoOutParams {
    var node = mpv_node()
    defer {
      mpv_free_node_contents(&node)
    }

    mpv_get_property(handle, "video-out-params", MPV_FORMAT_NODE, &node)

    if node.format != MPV_FORMAT_NODE_MAP {
      return MPVVideoOutParams.empty
    }

    let map: mpv_node_list = node.u.list!.pointee
    if map.num == 0 {
      return MPVVideoOutParams.empty
    }

    return MPVVideoOutParams.fromMPVNodeList(map)
  }

  // Duree reelle du contenu en secondes, lue via le meme handle mpv que
  // getVideoOutParams ci-dessus. Retourne 0 si absente/erreur - un flux
  // LIVE ne rapporte pas de "duration" positive, c'est volontairement le
  // signal utilise par l'appelant pour distinguer live/VOD sans info
  // supplementaire cote Dart.
  public static func getDuration(
    _ handle: OpaquePointer
  ) -> Double {
    var duration: Double = 0
    let status = mpv_get_property(
      handle, "duration", MPV_FORMAT_DOUBLE, &duration
    )
    if status < 0 {
      return 0
    }
    return duration
  }

  // Seek RELATIF en secondes (peut etre negatif), utilise par le geste
  // +-10/+-30 du transport systeme PiP. mpv_command est documente
  // thread-safe par libmpv depuis n'importe quel thread - appele
  // directement, sans dispatch dedie, EXACTEMENT comme mpv_get_property
  // ci-dessus (aucun autre appel de COMMANDE mpv, par opposition aux
  // lectures de propriete, n'existe ailleurs dans ce fork a ce jour -
  // pas de pattern preexistant a repliquer sur ce point precis).
  public static func seekRelative(
    _ handle: OpaquePointer,
    seconds: Double
  ) {
    // ⭐ 9 sept. 2026 — corrigé après échec de compilation réel (build
    // ios-testflight, erreur Swift à cette ligne) : mpv_command attend
    // UnsafePointer<CChar>?, pas UnsafeMutablePointer<CChar>? (le type que
    // strdup() renvoie nativement). On garde le pointeur MUTABLE à part
    // (pour le libérer) et on ne convertit qu'à l'insertion dans le tableau
    // passé à mpv_command.
    let args: [String] = ["seek", String(seconds), "relative"]
    let mutablePtrs: [UnsafeMutablePointer<CChar>?] = args.map { strdup($0) }
    var cArgs: [UnsafePointer<CChar>?] =
        mutablePtrs.map { $0.map { UnsafePointer($0) } }
    cArgs.append(nil)
    defer {
      mutablePtrs.forEach { if let p = $0 { free(p) } }
    }
    mpv_command(handle, &cArgs)
  }
}
