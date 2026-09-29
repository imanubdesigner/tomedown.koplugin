local _ = require("tomedown_i18n")

return {
    fullname = "Tomedown",
    description = _([[Exports each book's highlights into its own Markdown file,
with frontmatter and an index, and uploads them to your cloud.]]),
    -- the update check compares this with the GitHub release tags; bump it
    -- to the tag (without the "v") whenever a release is published
    version = "0.4.0-beta.1",
}
