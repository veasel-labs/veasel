import type { SkillCatalogEntry } from "../skill-autocomplete"

export type PluginSkillRow = {
  name: string
  description: string
  source?: string
  scope?: string
}

export type PluginCatalogPlugin = {
  name: string
  skills: PluginSkillRow[]
}

export type PluginCatalog = {
  plugins: PluginCatalogPlugin[]
}

export type SessionPluginSkill = {
  plugin_name: string
  skill_name: string
}

/** Flatten plugin catalog skills into `$`-mention keys (OpenCode/Veasel source/skill). */
export function skillCatalogFromPlugins(
  catalog: PluginCatalog | undefined,
  enabled?: readonly SessionPluginSkill[],
): SkillCatalogEntry[] {
  const enabledKeys = new Set(
    (enabled ?? []).map((item) => `${item.plugin_name}/${item.skill_name}`),
  )
  const entries: SkillCatalogEntry[] = []
  for (const plugin of catalog?.plugins ?? []) {
    for (const skill of plugin.skills) {
      const key = `${plugin.name}/${skill.name}`
      const mark = enabledKeys.size > 0 && enabledKeys.has(key) ? "enabled · " : ""
      entries.push({
        key,
        description: `${mark}${skill.description.replace(/\s+/g, " ").trim()}`,
      })
    }
  }
  return entries.sort((a, b) => a.key.localeCompare(b.key))
}
