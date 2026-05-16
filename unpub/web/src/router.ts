import { ref, onMounted, onUnmounted, computed, type Ref } from "vue";

export type Route =
  | { view: "list" }
  | { view: "detail"; name: string; version: string }
  | { view: "unknown" };

interface UseRouter {
  route: Ref<Route>;
  navigate: (path: string) => void;
}

export function useRouter(): UseRouter {
  const route = ref<Route>(parse(location.pathname));

  function parse(path: string): Route {
    if (path === "/" || path === "/packages" || path === "/packages/") {
      return { view: "list" };
    }
    const m = path.match(/^\/packages\/([^/]+)(?:\/versions\/(.+))?$/);
    if (m) {
      return {
        view: "detail",
        name: decodeURIComponent(m[1]),
        version: m[2] ? decodeURIComponent(m[2]) : "latest",
      };
    }
    return { view: "unknown" };
  }

  function navigate(path: string) {
    if (path !== location.pathname + location.search) {
      history.pushState(null, "", path);
    }
    route.value = parse(location.pathname);
  }

  function onPop() {
    route.value = parse(location.pathname);
  }

  onMounted(() => window.addEventListener("popstate", onPop));
  onUnmounted(() => window.removeEventListener("popstate", onPop));

  return { route, navigate };
}

export const origin = computed(() => window.location.origin);
