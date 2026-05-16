<script setup lang="ts">
import { ref, computed, watch, onMounted } from "vue";
import { getPackage, fmtDate } from "../api";
import type { PackageDetail } from "../types";

const props = defineProps<{ name: string; version: string }>();
const emit = defineEmits<{ navigate: [path: string] }>();

const detail = ref<PackageDetail | null>(null);
const error = ref("");
const loading = ref(true);

const origin = window.location.origin;
const tarballUrl = computed(() => {
  if (!detail.value) return "";
  return (
    origin +
    "/packages/" +
    encodeURIComponent(detail.value.name) +
    "/versions/" +
    encodeURIComponent(detail.value.version) +
    ".tar.gz"
  );
});

const installSnippet = computed(() => {
  if (!detail.value) return "";
  const n = detail.value.name;
  const v = detail.value.version;
  return [
    "# Add to pubspec.yaml:",
    "dependencies:",
    `  ${n}: ^${v}`,
    "",
    "# Using a custom registry:",
    "dependencies:",
    `  ${n}:`,
    `    hosted: ${origin}`,
    `    version: ^${v}`,
  ].join("\n");
});

async function load() {
  loading.value = true;
  error.value = "";
  detail.value = null;
  try {
    const res = await getPackage(props.name, props.version);
    if (res.error) {
      error.value = res.error;
    } else if (res.data) {
      detail.value = res.data;
    }
  } catch (e) {
    error.value = "Failed to load: " + (e instanceof Error ? e.message : String(e));
  } finally {
    loading.value = false;
  }
}

watch(() => [props.name, props.version], load);
onMounted(load);
</script>

<template>
  <div class="breadcrumb">
    <a href="/" @click.prevent="emit('navigate', '/')">← packages</a>
    &nbsp;/&nbsp;{{ props.name }}
  </div>

  <div v-if="loading" class="empty">Loading {{ props.name }}...</div>
  <div v-else-if="error" class="empty">{{ error }}</div>

  <template v-else-if="detail">
    <div class="detail-header">
      <h1>{{ detail.name }}</h1>
      <div>
        <span class="version">{{ detail.version }} · {{ fmtDate(detail.createdAt) }}</span>
      </div>
      <p v-if="detail.description" class="detail-desc">{{ detail.description }}</p>
    </div>

    <div class="detail-grid">
      <div>
        <div class="card">
          <div class="label">Install</div>
          <pre>{{ installSnippet }}</pre>
        </div>
        <div v-if="detail.readme" class="readme">
          <div class="label">README</div>
          <pre>{{ detail.readme }}</pre>
        </div>
        <div v-if="detail.changelog" class="readme">
          <div class="label">CHANGELOG</div>
          <pre>{{ detail.changelog }}</pre>
        </div>
      </div>

      <div>
        <div class="card">
          <div class="label">Metadata</div>
          <table class="meta-table">
            <tr><td>Latest</td><td>{{ detail.version }}</td></tr>
            <tr><td>Published</td><td>{{ fmtDate(detail.createdAt) }}</td></tr>
            <tr v-if="detail.homepage">
              <td>Homepage</td>
              <td>
                <a :href="detail.homepage" target="_blank" rel="noopener">{{ detail.homepage }}</a>
              </td>
            </tr>
            <tr v-if="detail.uploaders.length">
              <td>Uploaders</td><td>{{ detail.uploaders.join(", ") }}</td>
            </tr>
            <tr v-if="detail.authors.length">
              <td>Authors</td><td>{{ detail.authors.join(", ") }}</td>
            </tr>
            <tr v-if="detail.dependencies.length">
              <td>Dependencies</td><td>{{ detail.dependencies.join(", ") }}</td>
            </tr>
            <tr v-if="detail.tags.length">
              <td>Tags</td><td>{{ detail.tags.join(", ") }}</td>
            </tr>
          </table>
          <a :href="tarballUrl" style="display:inline-block;margin-top:8px">Download tarball</a>
        </div>

        <div v-if="detail.versions.length" class="card" style="margin-top:16px">
          <div class="label">Versions</div>
          <div class="versions-list">
            <a
              v-for="v in detail.versions"
              :key="v.version"
              :href="`/packages/${encodeURIComponent(detail.name)}/versions/${encodeURIComponent(v.version)}`"
              @click.prevent="emit('navigate', `/packages/${encodeURIComponent(detail.name)}/versions/${encodeURIComponent(v.version)}`)"
            >
              <span class="vname">{{ v.version }}</span>
              <span class="vdate">{{ fmtDate(v.createdAt) }}</span>
            </a>
          </div>
        </div>
      </div>
    </div>
  </template>
</template>

<style scoped>
.breadcrumb {
  color: var(--muted);
  margin-bottom: 12px;
  font-size: 14px;
}
.breadcrumb a {
  color: var(--muted);
}
.detail-header {
  margin-bottom: 20px;
}
.detail-header h1 {
  margin: 0 0 4px;
  font-size: 28px;
}
.detail-header .version {
  color: var(--muted);
  font-family: ui-monospace, Menlo, monospace;
}
.detail-desc {
  margin: 8px 0 0;
  color: var(--muted);
}
.detail-grid {
  display: grid;
  grid-template-columns: 2fr 1fr;
  gap: 24px;
}
@media (max-width: 800px) {
  .detail-grid {
    grid-template-columns: 1fr;
  }
}
.card {
  background: var(--panel);
  border: 1px solid var(--border);
  border-radius: 12px;
  padding: 18px 20px;
  margin-bottom: 12px;
}
.meta-table {
  width: 100%;
  border-collapse: collapse;
}
.meta-table td {
  padding: 6px 0;
  vertical-align: top;
}
.meta-table td:first-child {
  color: var(--muted);
  width: 40%;
  font-size: 13px;
}
.readme {
  background: var(--panel);
  border: 1px solid var(--border);
  border-radius: 12px;
  padding: 20px;
  margin-top: 16px;
}
.readme pre {
  white-space: pre-wrap;
}
.versions-list {
  max-height: 260px;
  overflow-y: auto;
  border: 1px solid var(--border);
  border-radius: 8px;
}
.versions-list a {
  display: flex;
  justify-content: space-between;
  align-items: center;
  padding: 8px 12px;
  border-bottom: 1px solid var(--border);
  color: var(--text);
}
.versions-list a:last-child {
  border-bottom: none;
}
.versions-list a:hover {
  background: var(--panel-2);
  text-decoration: none;
}
.versions-list .vname {
  font-family: ui-monospace, Menlo, monospace;
  font-size: 13px;
}
.versions-list .vdate {
  color: var(--muted);
  font-size: 12px;
}
</style>
