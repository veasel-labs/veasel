Fix the narrow-screen text overflow documented in veasel-labs/website#166. On
the landing page, long inline configuration names must wrap inside their value
cards. On the Evals page, each checklist item's prose must stay in normal
reading flow beside its status badge instead of breaking into separate grid
cells. Contain decorative horizontal overflow at the main content boundary,
but do not hide or clip text or remove code-block horizontal scrolling. Preserve
keyboard focus behavior and light/dark themes. Add or update focused regression
tests. Verify the changed pages at 320, 390, 768, and 1280 pixel widths in both
themes, then run the repository's format, test, check, and build commands. Keep
the change limited to this layout defect.
