"use strict";

function normalizeModelIds(values) {
  return [...new Set(
    (Array.isArray(values) ? values : [])
      .map((value) => String(value || "").trim())
      .filter(Boolean),
  )];
}

function buildModelObserverCompatibilityExpression(modelIds) {
  const normalizedIds = normalizeModelIds(modelIds);
  return `
    (() => {
      const catalogModelIds = ${JSON.stringify(normalizedIds)};
      const allowedIds = new Set(catalogModelIds);
      const signature = JSON.stringify(catalogModelIds);
      const anchors = [
        ...document.querySelectorAll('[data-codex-intelligence-trigger="true"]'),
        ...document.querySelectorAll('[data-app-action-sidebar-thread-row]'),
      ];
      if (anchors.length === 0) {
        return { status: "unavailable", message: "Codex React anchors were not found" };
      }

      const clients = [];
      const seenClients = new Set();
      const consider = (value) => {
        if (
          value &&
          typeof value === "object" &&
          typeof value.getQueryCache === "function" &&
          typeof value.invalidateQueries === "function" &&
          !seenClients.has(value)
        ) {
          seenClients.add(value);
          clients.push(value);
        }
      };

      for (const anchor of anchors) {
        const fiberKey = Object.keys(anchor).find((key) => key.startsWith("__reactFiber"));
        let fiber = fiberKey ? anchor[fiberKey] : null;
        for (let fiberIndex = 0; fiber && fiberIndex < 180; fiberIndex += 1, fiber = fiber.return) {
          const props = fiber.memoizedProps;
          consider(props);
          consider(props?.client);
          consider(props?.value);
          consider(props?.queryClient);

          let context = fiber.dependencies?.firstContext;
          for (
            let contextIndex = 0;
            context && contextIndex < 40;
            contextIndex += 1, context = context.next
          ) {
            consider(context.memoizedValue);
          }

          let hook = fiber.memoizedState;
          for (let hookIndex = 0; hook && hookIndex < 120; hookIndex += 1, hook = hook.next) {
            const value = hook.memoizedState;
            consider(value);
            if (Array.isArray(value)) consider(value[0]);
            consider(value?.client);
            consider(value?.value);
            consider(value?.queryClient);
          }
        }
        if (clients.length > 0) break;
      }

      if (clients.length === 0) {
        return { status: "unavailable", message: "Codex query client was not found" };
      }

      let modelQueryCount = 0;
      let observerCount = 0;
      let patchedObserverCount = 0;
      let restoredObserverCount = 0;
      let readyObserverCount = 0;
      const visibleCatalogModels = new Set();

      for (const client of clients) {
        const queries = client.getQueryCache().getAll().filter((query) =>
          query.queryKey?.[0] === "models" && query.queryKey?.[1] === "list",
        );
        for (const query of queries) {
          const rawModels = Array.isArray(query.state?.data?.data) ? query.state.data.data : [];
          const additions = rawModels.filter((model) => {
            const id = model?.model || model?.id;
            return allowedIds.has(id) && model?.hidden !== true;
          });
          const observers = query.observers || [];
          const hasCompatibilityPatch = observers.some(
            (observer) => typeof observer.options?.select?.__dockerCodexOriginalSelect === "function",
          );
          if (additions.length === 0 && !hasCompatibilityPatch) continue;

          modelQueryCount += 1;
          for (const model of additions) {
            const id = model?.model || model?.id;
            if (id) visibleCatalogModels.add(id);
          }

          let queryOptionsChanged = false;
          for (const observer of observers) {
            observerCount += 1;
            const currentSelect = observer.options?.select;
            if (typeof currentSelect !== "function") continue;
            const originalSelect = currentSelect.__dockerCodexOriginalSelect || currentSelect;

            if (additions.length === 0) {
              if (currentSelect.__dockerCodexOriginalSelect) {
                observer.setOptions({ ...observer.options, select: originalSelect });
                restoredObserverCount += 1;
                queryOptionsChanged = true;
              }
              continue;
            }

            const currentIds = new Set(
              (observer.getCurrentResult()?.data?.models || [])
                .map((model) => model?.model || model?.id)
                .filter(Boolean),
            );
            const alreadyReady =
              currentSelect.__dockerCodexCatalogSignature === signature &&
              additions.every((model) => currentIds.has(model?.model || model?.id));
            if (alreadyReady) {
              readyObserverCount += 1;
              continue;
            }

            const patchedSelect = (raw) => {
              const selected = originalSelect(raw);
              const nextRawModels = Array.isArray(raw?.data) ? raw.data : [];
              const nextAdditions = nextRawModels.filter((model) => {
                const id = model?.model || model?.id;
                return allowedIds.has(id) && model?.hidden !== true;
              });
              const merged = [...(Array.isArray(selected?.models) ? selected.models : [])];
              const seen = new Set(merged.map((model) => model?.model || model?.id));
              for (const model of nextAdditions) {
                const id = model?.model || model?.id;
                if (id && !seen.has(id)) {
                  seen.add(id);
                  merged.push(model);
                }
              }
              return {
                ...selected,
                models: merged,
                defaultModel:
                  selected?.defaultModel || merged.find((model) => model?.isDefault) || null,
              };
            };
            patchedSelect.__dockerCodexOriginalSelect = originalSelect;
            patchedSelect.__dockerCodexCatalogSignature = signature;
            observer.setOptions({ ...observer.options, select: patchedSelect });
            patchedObserverCount += 1;
            queryOptionsChanged = true;
          }

          if (queryOptionsChanged && typeof query.setData === "function" && query.state?.data !== undefined) {
            const currentData = query.state.data;
            const clonedData = currentData && typeof currentData === "object"
              ? {
                  ...currentData,
                  data: Array.isArray(currentData.data)
                    ? currentData.data.map((model) => ({ ...model }))
                    : currentData.data,
                }
              : currentData;
            query.setData(clonedData);
          }
        }
      }

      if (modelQueryCount === 0) {
        return { status: "not-cached", catalogModelIds, modelQueryCount: 0, observerCount: 0 };
      }
      if (observerCount === 0) {
        return {
          status: "waiting",
          catalogModelIds,
          visibleCatalogModelIds: [...visibleCatalogModels],
          modelQueryCount,
          observerCount,
        };
      }
      return {
        status: "ready",
        catalogModelIds,
        visibleCatalogModelIds: [...visibleCatalogModels],
        modelQueryCount,
        observerCount,
        patchedObserverCount,
        restoredObserverCount,
        readyObserverCount,
      };
    })()
  `;
}

module.exports = {
  buildModelObserverCompatibilityExpression,
  normalizeModelIds,
};
