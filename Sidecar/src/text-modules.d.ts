// Markdown files imported with `with { type: "text" }` are bundled into the binary as strings.
declare module "*.md" {
    const content: string;
    export default content;
}
