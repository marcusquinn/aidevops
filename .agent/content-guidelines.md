# Content Guidelines for AI Copywriting

These guidelines define the standard for creating high-quality, human-sounding, SEO-optimized content for our websites (specifically tailored for local businesses like Trinity Joinery).

## 🎯 **Tone of Voice**

- **Authentic & Local:** Sound like a local expert, not a generic corporation. Use "We make..." instead of "Trinity Joinery crafts...".
- **Professional but Approachable:** Confident in expertise, but friendly to the homeowner.
- **British English:** Always use British spelling (e.g., `specialise`, `colour`, `moulding`, `draughty`, `centre`).
- **Direct:** Avoid fluff. Get to the point.

## 📝 **Formatting & Structure**

### **Paragraphs**

- **One Sentence Per Paragraph:** To improve readability on screens (especially mobile), break text down. Every major sentence gets its own block.
- **No Walls of Text:** Avoid paragraphs with 3+ lines.

### **Sentences**

- **Short & Punchy:** Keep sentences concise.
- **Use Dashes:** Use spaced em-dashes (` — `) to connect related thoughts or add emphasis, rather than long subordinate clauses.
  - *Good:* "We finish them with marine-grade coatings — they are built specifically to resist swelling."
  - *Bad:* "We finish them with marine-grade coatings, which means that they are built specifically..."

### **Keywords & SEO**

- **Bold Keywords:** Use strong emphasis to highlight primary keywords naturally within the text.
  - *Example:* "Hand-crafted here in Jersey, our bespoke **sash windows** are built to last."
- **Natural Placement:** Do not stuff keywords. If it sounds forced, rewrite it.
- **Long-Tail Variations:** Include variations like "Jersey heritage properties", "granite farmhouse windows", "coastal climate".

## 🚫 **Things to Avoid**

- **Robotic Phrasing:** Avoid "We pride ourselves on...", "Our commitment to excellence...", "Elevate your home with...". Show, don't tell.
- **Repetition:** Don't start every sentence with the brand name.
- **Empty Blocks:** Ensure no `<!-- wp:paragraph --><p></p><!-- /wp:paragraph -->` blocks are left at the end of sections.
- **Markdown in HTML Fields:** Use proper HTML tags in HTML content fields.

### **HTML Formatting Guidelines**

For HTML content fields (especially WordPress content areas), use these HTML tags instead of Markdown:

```html
<strong>Bold text</strong>
<em>Italic text</em>
<br>
<p>Paragraphs</p>
<h2>Headings</h2>
<ul><li>List items</li></ul>
```

**Note:** Markdown like `**bold**` does not render in HTML content fields.

## 🛠️ **Workflow for Content Updates**

1. **Fetch:** Download the current content using `wp post get`.
    - **CRITICAL:** Use `--field=content` (singular) to get raw HTML without table headers/metadata.
    - *Correct:* `wp post get 123 --field=content > file.txt`
    - *Incorrect:* `wp post get 123 --fields=post_title,content > file.txt` (This adds "Field/Value" table artifacts to the file).
2. **Refine:** Apply these guidelines (split sentences, fix spelling, add bolding).
3. **Structure:** Ensure valid block markup (`<!-- wp:paragraph -->...`).
4. **Update:** Upload and apply via `wp post update`.
5. **Verify:** Flush caches (`wp closte devmode enable` if on Closte) and check frontend.

## 📄 **Example Transformation**

**Before (AI/Generic):**
> Trinity Joinery uses durable hardwoods treated to resist Jersey’s salt air and humidity effectively. Expert carpenters apply marine-grade finishes for long-lasting protection with minimal upkeep.

**After (Human/Local):**
> Absolutely.
>
> We know how harsh the salt air and damp can be.
>
> That’s why we use high-performance, rot-resistant timbers like Accoya and Sapele.
>
> We finish them with marine-grade coatings — ensuring they resist swelling, warping and weathering.

---
**Follow these guidelines for all product page updates.**
