// Package profilecompat expands optional desktop settings in shared profiles.
package profilecompat

import (
	"errors"
	"fmt"

	"gopkg.in/yaml.v3"
)

// DesktopKey is ignored by clients that only understand standard Clash keys.
const DesktopKey = "x-flclash-desktop"

// ExpandDesktop restores desktop-only nodes, groups and DNS policies before the
// normal core parser runs. Profiles without the extension are returned verbatim.
// Errors describe the schema, never profile values such as node credentials.
func ExpandDesktop(input []byte) ([]byte, error) {
	var root map[string]any
	if err := yaml.Unmarshal(input, &root); err != nil {
		return nil, errors.New("invalid profile YAML")
	}
	raw, exists := root[DesktopKey]
	if !exists {
		return input, nil
	}
	ext, ok := raw.(map[string]any)
	if !ok {
		return nil, schemaError("extension must be a mapping")
	}
	for key := range ext {
		switch key {
		case "proxies", "proxy-order", "proxy-groups", "dns":
		default:
			return nil, schemaError("unsupported extension field")
		}
	}

	_, hasOrder := ext["proxy-order"]
	if _, add := ext["proxies"]; add || hasOrder {
		common, err := namedList(root["proxies"], "proxies", true)
		if err != nil {
			return nil, err
		}
		extra, err := namedList(ext["proxies"], "extension proxies", true)
		if err != nil {
			return nil, err
		}
		combined := append(common, extra...)
		byName := make(map[string]any, len(combined))
		for _, item := range combined {
			name := item.(map[string]any)["name"].(string)
			if _, duplicate := byName[name]; duplicate {
				return nil, schemaError("proxy names must be unique across common and extension lists")
			}
			byName[name] = item
		}
		if order, present := ext["proxy-order"]; present {
			names, ok := order.([]any)
			if !ok || len(names) != len(combined) {
				return nil, schemaError("proxy-order must list every merged proxy exactly once")
			}
			combined = make([]any, 0, len(names))
			for _, value := range names {
				name, ok := value.(string)
				item, exists := byName[name]
				if !ok || !exists {
					return nil, schemaError("proxy-order must list every merged proxy exactly once")
				}
				combined = append(combined, item)
				delete(byName, name)
			}
		}
		root["proxies"] = combined
	}
	if groups, present := ext["proxy-groups"]; present {
		list, err := namedList(groups, "extension proxy-groups", false)
		if err != nil {
			return nil, err
		}
		// Replace the common list, so clients can use different group membership
		// without changing a group's position or default selection on desktop.
		root["proxy-groups"] = list
	}
	if dns, present := ext["dns"]; present {
		overlay, ok := dns.(map[string]any)
		if !ok {
			return nil, schemaError("extension dns must be a mapping")
		}
		for key := range overlay {
			if key != "nameserver-policy" {
				return nil, schemaError("extension dns only supports nameserver-policy")
			}
		}
		if policy, present := overlay["nameserver-policy"]; present {
			entries, ok := policy.(map[string]any)
			if !ok {
				return nil, schemaError("extension nameserver-policy must be a mapping")
			}
			for _, value := range entries {
				if !validResolvers(value) {
					return nil, schemaError("extension DNS policies require a resolver string or nonempty string list")
				}
			}
			baseDNS, err := optionalMap(root, "dns")
			if err != nil {
				return nil, err
			}
			basePolicy, err := optionalMap(baseDNS, "nameserver-policy")
			if err != nil {
				return nil, err
			}
			for name, value := range entries {
				basePolicy[name] = value
			}
		}
	}
	delete(root, DesktopKey)
	output, err := yaml.Marshal(root)
	if err != nil {
		return nil, schemaError("cannot encode expanded profile")
	}
	return output, nil
}

func namedList(value any, field string, optional bool) ([]any, error) {
	if value == nil && optional {
		return nil, nil
	}
	list, ok := value.([]any)
	if !ok {
		return nil, schemaError(field + " must be a list of named mappings")
	}
	seen := make(map[string]bool, len(list))
	for _, value := range list {
		item, ok := value.(map[string]any)
		if !ok {
			return nil, schemaError(field + " must be a list of named mappings")
		}
		name, ok := item["name"].(string)
		if !ok || name == "" || seen[name] {
			return nil, schemaError(field + " must have unique nonempty string names")
		}
		seen[name] = true
	}
	return list, nil
}

func optionalMap(parent map[string]any, key string) (map[string]any, error) {
	if value, exists := parent[key]; exists && value != nil {
		mapping, ok := value.(map[string]any)
		if !ok {
			return nil, schemaError(key + " must be a mapping")
		}
		return mapping, nil
	}
	mapping := make(map[string]any)
	parent[key] = mapping
	return mapping, nil
}

func validResolvers(value any) bool {
	if resolver, ok := value.(string); ok {
		return resolver != ""
	}
	list, ok := value.([]any)
	if !ok || len(list) == 0 {
		return false
	}
	for _, entry := range list {
		if resolver, ok := entry.(string); !ok || resolver == "" {
			return false
		}
	}
	return true
}

func schemaError(message string) error {
	return fmt.Errorf("%s: %s", DesktopKey, message)
}
