<script setup lang="ts">
import { computed, ref, watch, onMounted } from "vue";
import {
  listPackages,
  fmtDate,
  searchUpstream,
  cacheFromUpstream,
} from "../api";
import type {
  PackageSummary,
  SortKey,
  UpstreamPackageRef,
} from "../types";

const props = defineProps<{ query: string }>();
const emit = defineEmits<{ navigate: [path: string] }>();

const packages = ref<PackageSummary[]>([]);
const count = ref(0);
const loading = ref(true);
const sort = ref<SortKey>("download");
const page = ref(0);
const size = 20;

const upstreamResults = ref<UpstreamPackageRef[]>([]);
const upstreamLoading = ref(false);
const caching = ref<Record<string, "pending" | "done" | string>>({});

const pages = computed(() => Math.max(1, Math.ceil(count.value / size)));

const localNames = computed(
  () => new Set(packages.value.map((p) => p.name)),
);
const upstreamOnly = computed(() =>
  upstreamResults.value.filter((u) => !localNames.value.has(u.name)),
);

async function load() {
  loading.value = true;
  try {
    const res = await listPackages({
      size,
      page: page.value,
      sort: sort.value,
      q: props.query || undefined,
    });
    packages.value = res.data?.packages ?? [];
    count.value = res.data?.count ?? 0;
  } catch {
    packages.value = [];
    count.value = 0;
  } finally {
    loading.value = false;
  }
}

async function loadUpstream() {
  if (!props.query) {
    upstreamResults.value = [];
    return;
  }
  upstreamLoading.value = true;
  try {
    const res = await searchUpstream(props.query);
    upstreamResults.value = res.data?.packages ?? [];
  } catch {
    upstreamResults.value = [];
  } finally {
    upstreamLoading.value = false;
  }
}

async function pullFromUpstream(name: string) {
  caching.value[name] = "pending";
  try {
    await cacheFromUpstream(name);
    caching.value[name] = "done";
    await load();
  } catch (e) {
    caching.value[name] =
      "error: " + (e instanceof Error ? e.message : String(e));
  }
}

watch(() => props.query, () => {
  page.value = 0;
  load();
  loadUpstream();
});
watch([sort, page], () => load());

onMounted(() => {
  load();
  loadUpstream();
});
</script>

<template>
  <div class="controls">
    <span>
      <template v-if="loading">Loading...</template>
      <template v-else-if="count === 0">No packages match</template>
      <template v-else-if="props.query">Found {{ count }} for "{{ props.query }}"</template>
      <template v-else>{{ count }} package{{ count === 1 ? "" : "s" }}</template>
    </span>
    <div class="right">
      <select v-model="sort" @change="page = 0">
        <option value="download">Most downloaded</option>
        <option value="updated">Recently updated</option>
        <option value="createdAt">Newest</option>
      </select>
    </div>
  </div>

  <div v-if="loading">
    <div v-for="i in 5" :key="i" class="card">
      <div class="skel" style="height: 22px; width: 40%; margin-bottom: 10px" />
      <div class="skel" style="height: 14px; width: 90%; margin-bottom: 6px" />
      <div class="skel" style="height: 14px; width: 70%" />
    </div>
  </div>

  <template v-else>
    <div v-if="packages.length === 0" class="empty">
      No packages yet — publish with
      <code>dart pub publish --server={{ origin }}</code>
      or wait for upstream cache fill.
    </div>

    <a
      v-for="p in packages"
      :key="p.name"
      class="card link"
      :href="`/packages/${encodeURIComponent(p.name)}`"
      @click.prevent="emit('navigate', `/packages/${encodeURIComponent(p.name)}`)"
    >
      <div class="row1">
        <span class="pkg-name">{{ p.name }}</span>
        <span class="pkg-version">{{ p.latest }}</span>
        <span class="pkg-updated">{{ fmtDate(p.updatedAt) }}</span>
      </div>
      <div v-if="p.description" class="pkg-desc">{{ p.description }}</div>
      <div v-if="p.tags && p.tags.length" class="tags">
        <span v-for="t in p.tags" :key="t" class="tag">{{ t }}</span>
      </div>
    </a>

    <div v-if="pages > 1" class="pagination">
      <button :disabled="page === 0" @click="page--">Prev</button>
      <span style="align-self: center; color: var(--muted)">
        Page {{ page + 1 }} of {{ pages }}
      </span>
      <button :disabled="page + 1 >= pages" @click="page++">Next</button>
    </div>

    <section v-if="props.query && upstreamOnly.length" class="upstream-block">
      <div class="upstream-header">
        <div class="label">On pub.dev (not cached yet)</div>
        <span class="hint">click "Pull to cache" to mirror into S3 + DDB</span>
      </div>
      <div
        v-for="u in upstreamOnly"
        :key="u.name"
        class="card upstream-card"
      >
        <div class="row1">
          <a
            class="pkg-name"
            :href="`https://pub.dev/packages/${encodeURIComponent(u.name)}`"
            target="_blank"
            rel="noopener"
            >{{ u.name }}</a
          >
          <span class="pkg-version">pub.dev</span>
          <span style="margin-left: auto">
            <button
              :disabled="caching[u.name] === 'pending'"
              class="pull-btn"
              @click="pullFromUpstream(u.name)"
            >
              <template v-if="caching[u.name] === 'pending'">Pulling…</template>
              <template v-else-if="caching[u.name] === 'done'">Cached ✓</template>
              <template v-else>Pull to cache</template>
            </button>
          </span>
        </div>
        <div
          v-if="caching[u.name] && caching[u.name]!.startsWith('error')"
          class="pull-err"
        >
          {{ caching[u.name] }}
        </div>
      </div>
    </section>
    <div v-else-if="props.query && upstreamLoading" class="hint" style="margin-top:12px">
      Checking pub.dev…
    </div>
  </template>
</template>

<script lang="ts">
const origin = window.location.origin;
</script>

<style scoped>
.controls {
  display: flex;
  gap: 8px;
  align-items: center;
  margin-bottom: 16px;
  color: var(--muted);
  font-size: 14px;
}
.controls .right {
  margin-left: auto;
  display: flex;
  gap: 8px;
}
.controls select {
  background: var(--panel);
  color: var(--text);
  border: 1px solid var(--border);
  border-radius: 8px;
  padding: 6px 10px;
  font: inherit;
}
.card {
  background: var(--panel);
  border: 1px solid var(--border);
  border-radius: 12px;
  padding: 18px 20px;
  margin-bottom: 12px;
  transition: border-color 0.12s ease;
}
.card.link {
  display: block;
  color: inherit;
  text-decoration: none;
}
.card.link:hover {
  border-color: var(--accent);
  text-decoration: none;
}
.row1 {
  display: flex;
  gap: 12px;
  align-items: baseline;
  flex-wrap: wrap;
}
.pkg-name {
  font-size: 18px;
  font-weight: 600;
  color: var(--text);
}
.pkg-version {
  color: var(--muted);
  font-family: ui-monospace, Menlo, monospace;
  font-size: 14px;
}
.pkg-updated {
  color: var(--muted);
  font-size: 13px;
  margin-left: auto;
}
.pkg-desc {
  color: var(--text);
  margin-top: 6px;
  font-size: 14px;
}
.tags {
  margin-top: 10px;
  display: flex;
  gap: 6px;
  flex-wrap: wrap;
}
.tag {
  background: var(--tag);
  color: var(--muted);
  font-size: 12px;
  padding: 3px 8px;
  border-radius: 999px;
}
.pagination {
  display: flex;
  gap: 8px;
  justify-content: center;
  margin-top: 20px;
}
.pagination button {
  background: var(--panel);
  color: var(--text);
  border: 1px solid var(--border);
  border-radius: 8px;
  padding: 8px 14px;
  font: inherit;
  cursor: pointer;
}
.pagination button:disabled {
  opacity: 0.4;
  cursor: not-allowed;
}
.pagination button:hover:not(:disabled) {
  border-color: var(--accent);
}
.upstream-block {
  margin-top: 32px;
}
.upstream-header {
  display: flex;
  align-items: baseline;
  gap: 10px;
  margin-bottom: 8px;
}
.upstream-card {
  border-style: dashed;
}
.hint {
  color: var(--muted);
  font-size: 13px;
}
.pull-btn {
  background: var(--accent);
  color: white;
  border: none;
  border-radius: 8px;
  padding: 6px 12px;
  font: inherit;
  font-size: 13px;
  cursor: pointer;
}
.pull-btn:disabled {
  opacity: 0.6;
  cursor: progress;
}
.pull-btn:hover:not(:disabled) {
  filter: brightness(1.1);
}
.pull-err {
  color: #ff7e7e;
  font-size: 13px;
  margin-top: 8px;
}
</style>
