/// 短剧产物 URL：每一段都编码，避免路径里的空格/斜杠破坏路由。
function encodePath(path: string): string {
  return path
    .split("/")
    .filter((segment) => segment !== "")
    .map((segment) => encodeURIComponent(segment))
    .join("/");
}

export function episodeAssetUrl(
  seriesId: string,
  episodeId: string,
  path: string,
): string {
  const clean = path.startsWith("assets/") ? path.slice("assets/".length) : path;
  return `/api/drama/series/${encodeURIComponent(seriesId)}/episodes/${encodeURIComponent(
    episodeId,
  )}/assets/${encodePath(clean)}`;
}

export function seriesAssetUrl(seriesId: string, path: string): string {
  return `/api/drama/series/${encodeURIComponent(
    seriesId,
  )}/assets/${encodePath(path)}`;
}
