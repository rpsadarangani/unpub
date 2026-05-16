// Shape of /webapi responses returned by the unpub Dart server.
// Keep these in sync with `unpub_api/lib/models.dart`.

export interface PackageSummary {
  name: string;
  description?: string | null;
  tags?: string[] | null;
  latest: string;
  updatedAt: string;
}

export interface ListResponse {
  data?: {
    count: number;
    packages: PackageSummary[];
  };
}

export interface VersionRef {
  version: string;
  createdAt: string;
}

export interface PackageDetail {
  name: string;
  version: string;
  description: string;
  homepage: string;
  uploaders: string[];
  createdAt: string;
  readme?: string | null;
  changelog?: string | null;
  versions: VersionRef[];
  authors: string[];
  dependencies: string[];
  tags: string[];
}

export interface DetailResponse {
  data?: PackageDetail;
  error?: string;
}

export type SortKey = "download" | "updated" | "createdAt";

export interface UpstreamPackageRef {
  name: string;
}

export interface UpstreamSearchResponse {
  data?: {
    packages: UpstreamPackageRef[];
  };
}

export interface UpstreamCacheResponse {
  data?: {
    name: string;
    versions: number;
    latest?: string;
  };
}
