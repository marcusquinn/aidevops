---
description: Secure Custom Fields (SCF) / Advanced Custom Fields (ACF) - field groups, data schema, programmatic updates
mode: subagent
temperature: 0.2
tools:
  write: true
  edit: true
  bash: true
  read: true
  glob: true
  grep: true
  webfetch: true
  task: true
  wordpress-mcp_*: true
  context7_*: true
---

# Secure Custom Fields (SCF) / ACF Subagent

<!-- AI-CONTEXT-START -->

## Quick Reference

- **Plugin**: Secure Custom Fields (SCF) — community fork of ACF
- **Field Groups**: `acf-field-group` post type
- **Fields**: `acf-field` post type
- **Meta Storage**: `{field_name}` = value, `_{field_name}` = field key reference

**Critical Rules**:

1. **Select fields**: `return_format` → `"value"`, save choice KEY not label
2. **Checkbox fields**: `return_format` → `"value"`, save array of choice KEYS
3. **Group sub-fields**: Separate `acf-field` posts with `post_parent` = group field ID
4. **Field key references**: Always set `_{field_name}` meta to the field key

**Common Issues**:

- Wrong value displayed → missing `_{field_name}` meta key reference
- Group sub-fields not saving → sub-fields in `post_content` instead of separate posts
- Select shows default → `return_format` not `"value"`

<!-- AI-CONTEXT-END -->

## Database Schema

**Field groups** (`post_type = 'acf-field-group'`):

```sql
SELECT ID, post_title, post_name, post_status FROM wp_posts WHERE post_type = 'acf-field-group';
```

| Column | Purpose |
|--------|---------|
| `post_name` | Unique key (`group_abc123`) |
| `post_content` | Serialized settings (location rules) |
| `post_status` | `publish` or `acf-disabled` |

**Fields** (`post_type = 'acf-field'`):

```sql
SELECT ID, post_title, post_name, post_excerpt, post_parent, menu_order
FROM wp_posts WHERE post_type = 'acf-field' AND post_parent = {group_id} ORDER BY menu_order;
```

| Column | Purpose |
|--------|---------|
| `post_name` | Field key (`field_abc123`) |
| `post_excerpt` | Field name (used as `meta_key`) |
| `post_parent` | Parent field group ID (or group field ID for sub-fields) |
| `post_content` | Serialized field configuration |

**Field values** (`wp_postmeta`): `{field_name}` = value · `_{field_name}` = field key reference (REQUIRED)

## Group Fields with Sub-Fields

Sub-fields must be **separate `acf-field` posts** with `post_parent` = the group field's ID. Storing them in `post_content` does not work.

```php
// 1. Create the group field (empty sub_fields array)
$group_field_id = wp_insert_post([
    'post_title'   => 'My Group',
    'post_name'    => 'field_my_group',
    'post_excerpt' => 'my_group',
    'post_type'    => 'acf-field',
    'post_status'  => 'publish',
    'post_parent'  => $field_group_id,  // Parent is the field GROUP
    'menu_order'   => 0,
    'post_content' => serialize([
        'type' => 'group', 'name' => 'my_group', 'key' => 'field_my_group',
        'label' => 'My Group', 'layout' => 'block', 'sub_fields' => []
    ])
]);

// 2. Create each sub-field as a separate post
wp_insert_post([
    'post_title'   => 'Sub Field 1',
    'post_name'    => 'field_sub1',
    'post_excerpt' => 'sub1',
    'post_type'    => 'acf-field',
    'post_status'  => 'publish',
    'post_parent'  => $group_field_id,  // Parent is the GROUP FIELD, not field group
    'menu_order'   => 0,
    'post_content' => serialize(['key' => 'field_sub1', 'name' => 'sub1', 'label' => 'Sub Field 1', 'type' => 'text'])
]);
```

## Field Type Configuration

### Select Fields

`return_format` must be `"value"`. Save the choice KEY, not the label.

```php
$select_config = [
    'key' => 'field_my_select', 'name' => 'my_select', 'label' => 'My Select',
    'type' => 'select',
    'choices' => ['option1' => 'Option One', 'option2' => 'Option Two'],
    'default_value' => 'option1',
    'return_format' => 'value',  // CRITICAL
    'multiple' => 0
];
update_field('my_select', 'option1', $post_id);  // KEY, not 'Option One'
```

### Checkbox Fields

`return_format` must be `"value"`. Save array of choice keys.

```php
$checkbox_config = [
    'key' => 'field_my_checkboxes', 'name' => 'my_checkboxes', 'label' => 'My Checkboxes',
    'type' => 'checkbox',
    'choices' => ['Google My Business' => 'Google My Business', 'Facebook Page' => 'Facebook Page'],
    'return_format' => 'value'  // CRITICAL
];
update_field('my_checkboxes', ['Google My Business', 'Facebook Page'], $post_id);
```

### Other Field Types

| Type | Config key | Value format | Example |
|------|-----------|--------------|---------|
| `true_false` | `'ui' => 1, 'default_value' => 0` | `1` / `0` | `update_field('my_toggle', 1, $post_id)` |
| `date_time_picker` | `'display_format' => 'd/m/Y H:i', 'return_format' => 'Y-m-d H:i:s'` | ISO string | `update_field('my_datetime', '2024-01-15 09:30:00', $post_id)` |

## Programmatic Field Updates

```php
// Always set both value and key reference
function set_acf_field($post_id, $field_name, $value, $field_key) {
    update_field($field_name, $value, $post_id);
    update_post_meta($post_id, '_' . $field_name, $field_key);
}

// Simple field
set_acf_field($post_id, 'import_source', 'outscraper', 'field_import_source');

// Checkbox (array of keys)
set_acf_field($post_id, 'social_media_links', ['Google My Business', 'Google Maps'], 'field_abc123');

// Group sub-field (use full prefixed name)
set_acf_field($post_id, 'import_metadata_import_source', 'outscraper', 'field_import_source');

// Conditional fields: set checkbox first, then dependent fields
update_field('social_media_social_media_links', ['Google My Business', 'Google Maps'], $post_id);
update_post_meta($post_id, '_social_media_social_media_links', 'field_646a475722f13');
update_field('social_media_google_my_business', 'maps.google.com/...', $post_id);
update_post_meta($post_id, '_social_media_google_my_business', 'field_646a486822f14');
```

## Troubleshooting

| Symptom | Cause | Fix |
|---------|-------|-----|
| Wrong/default value | Missing `_{field_name}` meta | `update_post_meta($post_id, '_field_name', 'field_abc123')` |
| Group sub-fields not saving | Sub-fields in `post_content` | Recreate as separate `acf-field` posts |
| Select shows default | `return_format` not `"value"` or saving label | Fix config (see below) or save key |
| Duplicate field keys | Multiple posts with same `post_name` | Delete duplicates |
| Values in wrong meta keys | Empty `post_excerpt` | Update `post_excerpt` and `post_content` config |

**Fix select `return_format` via database**:

```php
global $wpdb;
$field_post = $wpdb->get_row("SELECT * FROM {$wpdb->posts} WHERE post_name = 'field_key_here'");
$config = maybe_unserialize($field_post->post_content);
$config['return_format'] = 'value';
$config['multiple'] = 0;
$wpdb->update($wpdb->posts, ['post_content' => serialize($config)], ['ID' => $field_post->ID]);
wp_cache_flush();
```

**Check for duplicate field keys**:

```php
global $wpdb;
$duplicates = $wpdb->get_results("SELECT post_name, COUNT(*) as count FROM {$wpdb->posts}
    WHERE post_type = 'acf-field' GROUP BY post_name HAVING count > 1");
```

**Fix empty `post_excerpt`**:

```php
$wpdb->update($wpdb->posts, ['post_excerpt' => 'correct_name'], ['ID' => $field_id]);
$config = maybe_unserialize($field_post->post_content);
$config['name'] = 'correct_name';
$wpdb->update($wpdb->posts, ['post_content' => serialize($config)], ['ID' => $field_id]);
```

## WP-CLI Commands

```bash
# List field groups
wp post list --post_type=acf-field-group --fields=ID,post_title,post_name

# List fields in a group
wp eval 'global $wpdb; $fields = $wpdb->get_results("SELECT ID, post_name, post_excerpt, menu_order
    FROM {$wpdb->posts} WHERE post_type = \"acf-field\" AND post_parent = 24 ORDER BY menu_order");
    foreach ($fields as $f) { echo $f->ID . " | " . $f->post_name . " | " . $f->post_excerpt . "\n"; }'

# Check field configuration
wp eval '$field = acf_get_field("field_key_here"); print_r($field);'

# Check post meta values
wp post meta list {post_id} | grep field_name

# Set field value with key reference
wp eval '$post_id = 123; update_field("field_name", "value", $post_id);
    update_post_meta($post_id, "_field_name", "field_key_here"); echo "Done";'

# Discover field key from field name
wp eval 'global $wpdb; $field = $wpdb->get_row("SELECT post_name FROM {$wpdb->posts}
    WHERE post_type = \"acf-field\" AND post_excerpt = \"field_name_here\""); echo $field->post_name;'

# Discover field key via ACF API
wp eval '$groups = acf_get_field_groups(); foreach ($groups as $group) {
    $fields = acf_get_fields($group["key"]);
    foreach ($fields as $field) { if ($field["name"] === "field_name_here") echo $field["key"]; }}'
```

## Related Documentation

| Topic | File |
|-------|------|
| WordPress development | `wp-dev.md` |
| WordPress admin tasks | `wp-admin.md` |
| LocalWP database access | `localwp.md` |
| Preferred plugins | `wp-preferred.md` |
