import type { VeaselApiClient } from "../api-client"
import type { DialogHost } from "./ui/dialog"
import type { ToastHost } from "./ui/toast"
import { openDialogAlert } from "./ui/dialog-alert"
import { openDialogConfirm } from "./ui/dialog-confirm"
import { openDialogPrompt } from "./ui/dialog-prompt"
import { openDialogSelect } from "./ui/dialog-select"

export function createLivePluginWorkflows(deps: {
  api: VeaselApiClient
  dialog: DialogHost
  toast: ToastHost
  setComposerFocused: (focused: boolean) => void
}) {
  const { api, dialog, toast, setComposerFocused } = deps

  const openPlugins = async (filter = "") => {
    setComposerFocused(false)
    try {
      const catalog = await api.listPluginLinks()
      const needle = filter.trim().toLowerCase()
      const links = catalog.links.filter((link) => {
        if (!needle) return true
        const haystack = `${link.name} ${link.path} ${link.display_name ?? ""} ${link.description ?? ""}`.toLowerCase()
        return needle.split(/\s+/).every((token) => haystack.includes(token))
      })
      if (links.length === 0) {
        openDialogAlert(dialog, {
          title: "Plugins",
          message: needle
            ? `No plugin links match “${filter.trim()}”.`
            : "No managed plugin links. Use /plugin add [--replace] <absolute-path> (headless) to link a local Agent Plugin package.",
          onConfirm: () => setComposerFocused(true),
        })
        return
      }
      openDialogSelect(dialog, {
        title: "Plugin links",
        placeholder: "Filter plugins…",
        options: links.map((link) => ({
          title: link.display_name?.trim() || link.name,
          value: link.name,
          description: link.path,
          searchText: `${link.name} ${link.path} ${link.display_name ?? ""} ${link.description ?? ""}`,
        })),
        onSelect: (option) => {
          toast.info(`Linked · ${option.value}`, "Plugins")
          setComposerFocused(true)
        },
        onCancel: () => setComposerFocused(true),
        footer: "Enter selects · /plugin add|remove stays headless for now",
      })
    } catch (error) {
      openDialogAlert(dialog, {
        title: "Plugins",
        message: error instanceof Error ? error.message : "could not list plugin links",
        onConfirm: () => setComposerFocused(true),
      })
    }
  }

  const remove = async (name: string) => {
    setComposerFocused(false)
    try {
      const catalog = await api.listPluginLinks()
      const link = catalog.links.find((item) => item.name === name)
      if (!link) {
        toast.info(`Plugin link ${name} is no longer managed`, "Plugins")
        setComposerFocused(true)
        return
      }
      openDialogConfirm(dialog, {
        title: "Remove plugin link?",
        message: `Remove ${link.name} from Veasel's managed plugins? This removes only its managed symlink and registry entry; package files remain untouched.\n${link.path}`,
        label: { confirm: "Remove link", cancel: "Keep link" },
        onClose: () => setComposerFocused(true),
        onConfirm: () => {
          void api.removePluginLink(link.name).then(() => {
            toast.success(`Removed plugin link · ${link.name}`, "Plugins")
          }).catch((error) => {
            openDialogAlert(dialog, {
              title: "Plugin removal failed",
              message: error instanceof Error ? error.message : "could not remove plugin link",
              onConfirm: () => setComposerFocused(true),
            })
          }).finally(() => setComposerFocused(true))
        },
      })
    } catch (error) {
      openDialogAlert(dialog, {
        title: "Plugin removal failed",
        message: error instanceof Error ? error.message : "could not load plugin link",
        onConfirm: () => setComposerFocused(true),
      })
    }
  }

  const add = (rawPath?: string, replace = false) => {
    const path = rawPath?.trim()
    if (!path) {
      setComposerFocused(false)
      openDialogPrompt(dialog, {
        title: "Add local Agent Plugin",
        description: "Choose an absolute path to an existing package directory. Veasel links it without copying or downloading files.",
        placeholder: "/absolute/path/to/plugin",
        confirmLabel: "Validate and link",
        onConfirm: (value) => queueMicrotask(() => add(value, replace)),
        onCancel: () => setComposerFocused(true),
      })
      return
    }

    const perform = () => {
      void api.addPluginLink(path, replace).then((link) => {
        toast.success(`Linked plugin · ${link.name}`, "Plugins")
      }).catch((error) => {
        openDialogAlert(dialog, {
          title: "Plugin link failed",
          message: error instanceof Error ? error.message : "could not link plugin package",
          onConfirm: () => setComposerFocused(true),
        })
      }).finally(() => setComposerFocused(true))
    }

    if (!replace) {
      perform()
      return
    }
    setComposerFocused(false)
    openDialogConfirm(dialog, {
      title: "Replace plugin link?",
      message: `The validated package at this path may replace an existing managed link. Existing package files are not deleted.\n${path}`,
      label: { confirm: "Replace link", cancel: "Keep current link" },
      onClose: () => setComposerFocused(true),
      onConfirm: perform,
    })
  }

  return { openPlugins, add, remove }
}
