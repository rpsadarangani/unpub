<script setup lang="ts">
import { computed, ref, watch } from "vue";
import { useRouter } from "./router";
import PackageList from "./views/PackageList.vue";
import PackageDetail from "./views/PackageDetail.vue";

const { route, navigate } = useRouter();

const query = ref(
  new URLSearchParams(location.search).get("q") ?? "",
);

// Search drives navigation back to the list view. Debounce so typing isn't
// a request per keystroke.
let timer: number | undefined;
watch(query, (q) => {
  if (timer !== undefined) window.clearTimeout(timer);
  timer = window.setTimeout(() => {
    const params = new URLSearchParams();
    if (q) params.set("q", q);
    const qs = params.toString();
    navigate(`/${qs ? `?${qs}` : ""}`);
  }, 200);
});

const isListView = computed(() => route.value.view === "list");
</script>

<template>
  <header class="top">
    <div class="container">
      <a href="/" class="brand" @click.prevent="navigate('/')">
        <span class="dot">up</span> unpub
      </a>
      <form class="search" @submit.prevent>
        <input
          v-model="query"
          type="search"
          placeholder="Search packages, or use email:user@x or dependency:pkg"
          autocomplete="off"
        />
      </form>
      <a class="nav-link" href="/metrics" title="Prometheus exposition">metrics</a>
      <a
        class="nav-link"
        href="https://github.com/rpsadarangani/unpub"
        target="_blank"
        rel="noopener"
        >github</a
      >
    </div>
  </header>

  <main class="container">
    <PackageList v-if="isListView" :query="query" @navigate="navigate" />
    <PackageDetail
      v-else-if="route.view === 'detail'"
      :name="route.name"
      :version="route.version"
      @navigate="navigate"
    />
    <div v-else class="empty">Not Found</div>
  </main>
</template>

<style scoped>
.top {
  position: sticky;
  top: 0;
  z-index: 10;
  background: var(--panel);
  border-bottom: 1px solid var(--border);
}
.top .container {
  display: flex;
  gap: 16px;
  align-items: center;
}
.brand {
  display: flex;
  align-items: center;
  gap: 10px;
  font-weight: 700;
  font-size: 18px;
  color: var(--text);
}
.brand .dot {
  width: 28px;
  height: 28px;
  border-radius: 6px;
  background: var(--accent);
  display: grid;
  place-items: center;
  color: #fff;
  font-family: ui-monospace, Menlo, monospace;
  font-size: 14px;
  font-weight: 700;
}
.search {
  flex: 1;
  display: flex;
}
.search input {
  width: 100%;
  padding: 10px 14px;
  border-radius: 999px;
  border: 1px solid var(--border);
  background: var(--panel-2);
  color: var(--text);
  font: inherit;
  outline: none;
}
.search input:focus {
  border-color: var(--accent);
}
.nav-link {
  color: var(--muted);
  padding: 8px 12px;
  border-radius: 8px;
  font-size: 14px;
}
.nav-link:hover {
  background: var(--panel-2);
  text-decoration: none;
}
main.container {
  padding-top: 24px;
  padding-bottom: 80px;
}
</style>
