import type {
  ListResponse,
  DetailResponse,
  SortKey,
  UpstreamSearchResponse,
  UpstreamCacheResponse,
} from "./types";

export async function listPackages(opts: {
  size: number;
  page: number;
  sort: SortKey;
  q?: string;
}): Promise<ListResponse> {
  const params = new URLSearchParams({
    size: String(opts.size),
    page: String(opts.page),
    sort: opts.sort,
  });
  if (opts.q) params.set("q", opts.q);
  const res = await fetch(`/webapi/packages?${params.toString()}`, {
    headers: { Accept: "application/json" },
  });
  if (!res.ok) throw new Error(`packages query failed: ${res.status}`);
  return res.json();
}

export async function getPackage(
  name: string,
  version: string,
): Promise<DetailResponse> {
  const url = `/webapi/package/${encodeURIComponent(name)}/${encodeURIComponent(version || "latest")}`;
  const res = await fetch(url, { headers: { Accept: "application/json" } });
  if (!res.ok) throw new Error(`detail query failed: ${res.status}`);
  return res.json();
}

export async function searchUpstream(q: string): Promise<UpstreamSearchResponse> {
  if (!q) return { data: { packages: [] } };
  const res = await fetch(
    `/webapi/upstream-search?q=${encodeURIComponent(q)}`,
    { headers: { Accept: "application/json" } },
  );
  if (!res.ok) throw new Error(`upstream-search failed: ${res.status}`);
  return res.json();
}

export async function cacheFromUpstream(
  name: string,
): Promise<UpstreamCacheResponse> {
  const res = await fetch(
    `/webapi/upstream-cache/${encodeURIComponent(name)}`,
    { method: "POST", headers: { Accept: "application/json" } },
  );
  const body = await res.json();
  if (!res.ok) {
    const msg =
      (body && (body.error?.message || body.message)) || `HTTP ${res.status}`;
    throw new Error(msg);
  }
  return body;
}

export function fmtDate(iso?: string | null): string {
  if (!iso) return "";
  const d = new Date(iso);
  if (Number.isNaN(d.getTime())) return "";
  const diff = (Date.now() - d.getTime()) / 1000;
  if (diff < 60) return "just now";
  if (diff < 3600) return `${Math.floor(diff / 60)}m ago`;
  if (diff < 86400) return `${Math.floor(diff / 3600)}h ago`;
  if (diff < 604800) return `${Math.floor(diff / 86400)}d ago`;
  return d.toISOString().slice(0, 10);
}
