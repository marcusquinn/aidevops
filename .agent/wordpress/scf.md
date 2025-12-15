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

- **Plugin**: Secure Custom Fields (SCF) - community fork of ACF
- **Field Groups**: Stored as `acf-field-group` post type
- **Fields**: Stored as `acf-field` post type
- **Meta Storage**: `{field_name}` for value, `_{field_name}` for field key reference

**Critical Rules**:
1. **Select fields**: Set `return_format` to "value" and save the value KEY not label
2. **Checkbox fields**: Set `return_format` to "value", save array of choice KEYS
3. **Group sub-fields**: Must be stored as SEPARATE `acf-field` posts with `post_parent` = group ID
4. **Field key references**: Always set `_{field_name}` meta to the field key for ACF to recognize values

**Common Issues**:
- Field shows wrong value: Missing `_{field_name}` meta key reference
- Group sub-fields not saving: Sub-fields stored in `post_content` instead of separate posts
- Select shows default: `return_format` not set to "value"

<!-- AI-CONTEXT-END -->

## Overview

This subagent handles Secure Custom Fields (SCF) and Advanced Custom Fields (ACF) tasks:

- Field group design and creation
- Programmatic field updates via WP-CLI/PHP
- Data import with proper field key references
- Troubleshooting field display issues

## Database Schema

### Field Groups

Field groups are stored as posts with `post_type = 'acf-field-group'`:

```sql
SELECT ID, post_title, post_name, post_status 
FROM wp_posts 
WHERE post_type = 'acf-field-group';
```

| Column | Purpose |
|--------|---------|
| `ID` | Field group ID |
| `post_title` | Display name |
| `post_name` | Unique key (e.g., `group_abc123`) |
| `post_content` | Serialized settings (location rules, etc.) |
| `post_status` | `publish` or `acf-disabled` |

### Fields

Fields are stored as posts with `post_type = 'acf-field'`:

```sql
SELECT ID, post_title, post_name, post_excerpt, post_parent, menu_order
FROM wp_posts 
WHERE post_type = 'acf-field' AND post_parent = {group_id}
ORDER BY menu_order;
```

| Column | Purpose |
|--------|---------|
| `ID` | Field ID |
| `post_title` | Field label |
| `post_name` | Field key (e.g., `field_abc123`) |
| `post_excerpt` | Field name (used in meta_key) |
| `post_parent` | Parent field group ID (or parent group field ID for sub-fields) |
| `post_content` | Serialized field configuration |
| `menu_order` | Display order |

### Field Values (Post Meta)

Field values are stored in `wp_postmeta`:

| Meta Key | Purpose |
|----------|---------|
| `{field_name}` | The actual value |
| `_{field_name}` | Field key reference (REQUIRED for ACF to recognize) |

**Example**:
```
meta_key: import_source
meta_value: outscraper

meta_key: _import_source  
meta_value: field_import_source
```

## Critical: Group Fields with Sub-Fields

### Wrong Way (Causes Issues)

Storing sub-fields inside the group's `post_content`:

```php
// DON'T DO THIS - sub-fields in post_content don't work properly
$group_config = [
    'type' => 'group',
    'name' => 'my_group',
    'sub_fields' => [
        ['key' => 'field_sub1', 'name' => 'sub1', 'type' => 'text'],
        ['key' => 'field_sub2', 'name' => 'sub2', 'type' => 'select'],
    ]
];
```

### Correct Way (Works Properly)

Store sub-fields as **separate `acf-field` posts** with `post_parent` set to the group field's ID:

```php
// 1. Create the group field (empty sub_fields)
$group_data = [
    'post_title' => 'My Group',
    'post_name' => 'field_my_group',
    'post_excerpt' => 'my_group',
    'post_type' => 'acf-field',
    'post_status' => 'publish',
    'post_parent' => $field_group_id,  // Parent is the field GROUP
    'menu_order' => 0,
    'post_content' => serialize([
        'type' => 'group',
        'name' => 'my_group',
        'key' => 'field_my_group',
        'label' => 'My Group',
        'layout' => 'block',
        'sub_fields' => []  // Empty - sub-fields are separate posts
    ])
];
$group_field_id = wp_insert_post($group_data);

// 2. Create each sub-field as a separate post
$sub_field_data = [
    'post_title' => 'Sub Field 1',
    'post_name' => 'field_sub1',
    'post_excerpt' => 'sub1',
    'post_type' => 'acf-field',
    'post_status' => 'publish',
    'post_parent' => $group_field_id,  // Parent is the GROUP FIELD, not field group
    'menu_order' => 0,
    'post_content' => serialize([
        'key' => 'field_sub1',
        'name' => 'sub1',
        'label' => 'Sub Field 1',
        'type' => 'text'
    ])
];
wp_insert_post($sub_field_data);
```

## Field Type Configuration

### Select Fields

**Required settings**:
- `return_format`: Must be `"value"` to return the choice key
- `multiple`: `0` for single, `1` for multiple
- `choices`: Array of `key => label` pairs

```php
$select_config = [
    'key' => 'field_my_select',
    'name' => 'my_select',
    'label' => 'My Select',
    'type' => 'select',
    'choices' => [
        'option1' => 'Option One',
        'option2' => 'Option Two',
    ],
    'default_value' => 'option1',
    'return_format' => 'value',  // CRITICAL
    'multiple' => 0
];
```

**Saving values**: Use the choice KEY, not the label:
```php
// Correct
update_field('my_select', 'option1', $post_id);

// Wrong - will not match
update_field('my_select', 'Option One', $post_id);
```

### Checkbox Fields

**Required settings**:
- `return_format`: Must be `"value"` to return choice keys
- `choices`: Array of `key => label` pairs

```php
$checkbox_config = [
    'key' => 'field_my_checkboxes',
    'name' => 'my_checkboxes',
    'label' => 'My Checkboxes',
    'type' => 'checkbox',
    'choices' => [
        'Google My Business' => 'Google My Business',
        'Facebook Page' => 'Facebook Page',
    ],
    'return_format' => 'value'  // CRITICAL
];
```

**Saving values**: Use array of choice keys:
```php
update_field('my_checkboxes', ['Google My Business', 'Facebook Page'], $post_id);
```

### True/False Fields

```php
$boolean_config = [
    'key' => 'field_my_toggle',
    'name' => 'my_toggle',
    'label' => 'My Toggle',
    'type' => 'true_false',
    'default_value' => 0,
    'ui' => 1  // Show as toggle switch
];
```

**Saving values**:
```php
update_field('my_toggle', 1, $post_id);  // or true
update_field('my_toggle', 0, $post_id);  // or false
```

### Date/Time Picker Fields

```php
$datetime_config = [
    'key' => 'field_my_datetime',
    'name' => 'my_datetime',
    'label' => 'My DateTime',
    'type' => 'date_time_picker',
    'display_format' => 'd/m/Y H:i',
    'return_format' => 'Y-m-d H:i:s'
];
```

## Programmatic Field Updates

### Using update_field()

```php
// Simple field
update_field('field_name', 'value', $post_id);

// With field key reference (recommended for imports)
update_field('field_name', 'value', $post_id);
update_post_meta($post_id, '_field_name', 'field_key_here');
```

### Group Sub-Fields

For fields inside a group, use the full prefixed name:

```php
// Group: import_metadata
// Sub-field: import_source

// Method 1: Full name
update_field('import_metadata_import_source', 'outscraper', $post_id);
update_post_meta($post_id, '_import_metadata_import_source', 'field_import_source');

// Method 2: Via group array (less reliable)
update_field('import_metadata', [
    'import_source' => 'outscraper',
    'import_query' => 'test'
], $post_id);
```

### Conditional Fields (Checkbox-Controlled)

When a field's visibility depends on a checkbox:

```php
// 1. First, set the checkbox values
update_field('social_media_social_media_links', ['Google My Business', 'Google Maps'], $post_id);
update_post_meta($post_id, '_social_media_social_media_links', 'field_646a475722f13');

// 2. Then set the conditional fields
update_field('social_media_google_my_business', 'maps.google.com/...', $post_id);
update_post_meta($post_id, '_social_media_google_my_business', 'field_646a486822f14');
```

## Troubleshooting

### Field Shows Wrong/Default Value

**Symptom**: Database has correct value but UI shows default.

**Cause**: Missing field key reference (`_{field_name}` meta).

**Fix**:
```php
// Check if key reference exists
$key_ref = get_post_meta($post_id, '_field_name', true);
echo "Key ref: " . ($key_ref ?: 'MISSING');

// Set the key reference
update_post_meta($post_id, '_field_name', 'field_abc123');
```

### Group Sub-Fields Not Saving

**Symptom**: Saving group fields puts values in wrong meta keys.

**Cause**: Sub-fields stored in group's `post_content` instead of separate posts.

**Diagnosis**:
```php
// Check if sub-fields are separate posts
global $wpdb;
$group_field_id = 123; // The group field's post ID
$sub_fields = $wpdb->get_results($wpdb->prepare(
    "SELECT ID, post_name, post_excerpt FROM {$wpdb->posts} 
     WHERE post_type = 'acf-field' AND post_parent = %d",
    $group_field_id
));
print_r($sub_fields);
// Should return sub-field posts, not empty
```

**Fix**: Recreate the group with sub-fields as separate posts (see "Correct Way" above).

### Select Field Shows Default Despite Correct Value

**Symptom**: Select dropdown shows "Manual Entry" but database has "outscraper".

**Causes**:
1. `return_format` not set to "value"
2. Saving the label instead of the key

**Diagnosis**:
```php
// Check field configuration
$field = acf_get_field('field_key_here');
echo "return_format: " . ($field['return_format'] ?? 'NOT SET');
```

**Fix via database**:
```php
global $wpdb;
$field_post = $wpdb->get_row("SELECT * FROM {$wpdb->posts} WHERE post_name = 'field_key_here'");
$config = maybe_unserialize($field_post->post_content);
$config['return_format'] = 'value';
$config['multiple'] = 0;
$wpdb->update($wpdb->posts, ['post_content' => serialize($config)], ['ID' => $field_post->ID]);
wp_cache_flush();
```

### Duplicate Field Keys

**Symptom**: Erratic behavior, wrong fields being updated.

**Diagnosis**:
```php
global $wpdb;
$duplicates = $wpdb->get_results("
    SELECT post_name, COUNT(*) as count 
    FROM {$wpdb->posts} 
    WHERE post_type = 'acf-field' 
    GROUP BY post_name 
    HAVING count > 1
");
print_r($duplicates);
```

**Fix**: Delete duplicate fields, keeping only the correct one.

### Field Name is Empty

**Symptom**: Values saved to wrong meta keys like `fieldgroup_` instead of `fieldgroup_subfield`.

**Diagnosis**:
```php
global $wpdb;
$empty_names = $wpdb->get_results("
    SELECT ID, post_name, post_excerpt 
    FROM {$wpdb->posts} 
    WHERE post_type = 'acf-field' AND (post_excerpt = '' OR post_excerpt IS NULL)
");
print_r($empty_names);
```

**Fix**: Update the `post_excerpt` (field name) and `post_content` config:
```php
$wpdb->update($wpdb->posts, ['post_excerpt' => 'correct_name'], ['ID' => $field_id]);
$config = maybe_unserialize($field_post->post_content);
$config['name'] = 'correct_name';
$wpdb->update($wpdb->posts, ['post_content' => serialize($config)], ['ID' => $field_id]);
```

## WP-CLI Commands

### List Field Groups

```bash
wp post list --post_type=acf-field-group --fields=ID,post_title,post_name
```

### List Fields in a Group

```bash
wp eval '
global $wpdb;
$fields = $wpdb->get_results("SELECT ID, post_name, post_excerpt, menu_order FROM {$wpdb->posts} WHERE post_type = \"acf-field\" AND post_parent = 24 ORDER BY menu_order");
foreach ($fields as $f) {
    echo $f->ID . " | " . $f->post_name . " | " . $f->post_excerpt . "\n";
}
'
```

### Check Field Configuration

```bash
wp eval '
$field = acf_get_field("field_key_here");
print_r($field);
'
```

### Check Post Meta Values

```bash
wp post meta list {post_id} | grep field_name
```

### Set Field Value with Key Reference

```bash
wp eval '
$post_id = 123;
update_field("field_name", "value", $post_id);
update_post_meta($post_id, "_field_name", "field_key_here");
echo "Done";
'
```

## Import Script Best Practices

When importing data programmatically:

```php
// 1. Always set both value and key reference
function set_acf_field($post_id, $field_name, $value, $field_key) {
    update_field($field_name, $value, $post_id);
    update_post_meta($post_id, '_' . $field_name, $field_key);
}

// 2. For select fields, use the choice KEY
set_acf_field($post_id, 'import_source', 'outscraper', 'field_import_source');

// 3. For checkboxes, use array of choice KEYS
set_acf_field($post_id, 'social_media_links', ['Google My Business', 'Google Maps'], 'field_abc123');

// 4. For group sub-fields, use full prefixed name
set_acf_field($post_id, 'group_name_sub_field', 'value', 'field_sub_field_key');
```

## Field Key Discovery

To find the correct field key for a field:

```bash
# Method 1: From database
wp eval '
global $wpdb;
$field = $wpdb->get_row("SELECT post_name FROM {$wpdb->posts} WHERE post_type = \"acf-field\" AND post_excerpt = \"field_name_here\"");
echo $field->post_name;
'

# Method 2: From ACF API
wp eval '
$groups = acf_get_field_groups();
foreach ($groups as $group) {
    $fields = acf_get_fields($group["key"]);
    foreach ($fields as $field) {
        if ($field["name"] === "field_name_here") {
            echo $field["key"];
        }
    }
}
'
```

## Related Documentation

| Topic | File |
|-------|------|
| WordPress development | `wp-dev.md` |
| WordPress admin tasks | `wp-admin.md` |
| LocalWP database access | `localwp.md` |
| Preferred plugins | `wp-preferred.md` |
