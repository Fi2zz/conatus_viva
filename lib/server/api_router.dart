/// Which handler serves an `/api/*` request.
enum ApiRoute {
  dialects,
  getEditModels,
  getModels,
  createT2v,
  getT2v,
  getT2vVideo,
  createImage,
  getImage,
  getImageFile,
  unknown,
}

/// Maps a request's [method] + [path] to the handler that serves it.
///
/// Kept apart from `PipelineServer` so the dispatch (and its precedence rules)
/// can be unit tested without binding a socket.
///
/// The file route (`getT2vVideo`) is matched before the generic `getT2v`,
/// otherwise `/api/t2v/<id>` would swallow `/api/t2v/<id>/video` and downloads
/// would return run metadata instead of the file.
ApiRoute apiRouteFor(String method, String path) {
  if (path == '/api/dialects' && method == 'GET') {
    return ApiRoute.dialects;
  }
  if (path == '/api/edit-models' && method == 'GET') {
    return ApiRoute.getEditModels;
  }
  if (path == '/api/models' && method == 'GET') {
    return ApiRoute.getModels;
  }
  if (path == '/api/t2v' && method == 'POST') {
    return ApiRoute.createT2v;
  }
  if (path.startsWith('/api/t2v/') && method == 'GET') {
    if (path.endsWith('/video')) return ApiRoute.getT2vVideo;
    return ApiRoute.getT2v;
  }
  if (path == '/api/images' && method == 'POST') {
    return ApiRoute.createImage;
  }
  if (path.startsWith('/api/images/') && method == 'GET') {
    if (path.split('/').length == 5) return ApiRoute.getImageFile;
    return ApiRoute.getImage;
  }
  return ApiRoute.unknown;
}
