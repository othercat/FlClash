#!/usr/bin/ruby

require 'digest'
require 'set'
require 'yaml'

RAW_PROFILE_PATH = ENV.fetch(
  'FLCLASH_RAW_PROFILE',
  '/Users/lirichard/Library/Mobile Documents/com~apple~CloudDocs/FIClash/20260712.yaml'
).freeze
EFFECTIVE_CONFIG_PATH = ENV.fetch(
  'FLCLASH_EFFECTIVE_CONFIG',
  File.join(Dir.home, 'Library', 'Application Support', 'com.follow.clash', 'config.yaml')
).freeze

def fail_safely(message)
  warn(message)
  exit(1)
end

def load_config(path, label)
  raw = File.read(path, mode: 'r:BOM|UTF-8')
  config = YAML.safe_load(raw, permitted_classes: [], permitted_symbols: [], aliases: true)
  fail_safely("#{label} root is not a mapping") unless config.is_a?(Hash)
  rules = config['rules']
  groups = config['proxy-groups']
  fail_safely("#{label} rules are not a list") unless rules.is_a?(Array)
  fail_safely("#{label} proxy groups are not a list") unless groups.is_a?(Array)

  {
    raw: raw,
    rules: rules,
    groups: groups
  }
rescue Errno::ENOENT
  fail_safely("#{label} is unavailable")
rescue Psych::Exception
  fail_safely("#{label} YAML could not be parsed")
end

def canonical_rule(value)
  return nil unless value.is_a?(String)

  value.strip.split(',', -1).map { |field| field.to_s.strip }.join(',')
end

def rule_parts(value)
  canonical = canonical_rule(value)
  return nil if canonical.nil? || canonical.empty?

  fields = canonical.split(',', -1)
  {
    canonical: canonical,
    type: fields.fetch(0, '').upcase,
    payload: fields.fetch(1, '').downcase,
    target: fields.fetch(2, '')
  }
end

def config_summary(bundle)
  parsed = bundle[:rules].each_with_index.filter_map do |rule, index|
    parts = rule_parts(rule)
    parts&.merge(index: index)
  end
  cloud_rules = parsed.select do |rule|
    rule[:type] == 'DOMAIN-SUFFIX' && rule[:payload] == 'cloud.microsoft'
  end
  wrong_cloud_rules = parsed.select do |rule|
    rule[:type] == 'DOMAIN-SUFFIX' && rule[:payload] == 'cloud.microsoft.com'
  end
  match_rules = parsed.select { |rule| rule[:type] == 'MATCH' }
  group_names = bundle[:groups].filter_map do |group|
    group.is_a?(Hash) ? group['name'].to_s : nil
  end.to_set
  canonical_rules = bundle[:rules].filter_map { |rule| canonical_rule(rule) }

  {
    file_fingerprint: Digest::SHA256.hexdigest(bundle[:raw]),
    rule_count: bundle[:rules].length,
    string_rule_count: canonical_rules.length,
    non_string_rule_count: bundle[:rules].length - canonical_rules.length,
    canonical_rules: canonical_rules,
    order_fingerprint: Digest::SHA256.hexdigest(canonical_rules.join("\0")),
    cloud_count: cloud_rules.length,
    wrong_cloud_count: wrong_cloud_rules.length,
    cloud_index: cloud_rules.length == 1 ? cloud_rules[0][:index] : nil,
    cloud_target: cloud_rules.length == 1 ? cloud_rules[0][:target] : nil,
    cloud_target_exists: cloud_rules.length == 1 && group_names.include?(cloud_rules[0][:target]),
    match_count: match_rules.length,
    match_index: match_rules.length == 1 ? match_rules[0][:index] : nil,
    match_is_last: match_rules.length == 1 && match_rules[0][:index] == bundle[:rules].length - 1,
    cloud_before_match: cloud_rules.length == 1 && match_rules.length == 1 &&
      cloud_rules[0][:index] < match_rules[0][:index]
  }
end

def multiset_shared_count(left, right)
  left_counts = left.each_with_object(Hash.new(0)) { |rule, counts| counts[rule] += 1 }
  right_counts = right.each_with_object(Hash.new(0)) { |rule, counts| counts[rule] += 1 }
  left_counts.sum { |rule, count| [count, right_counts[rule]].min }
end

def self_test
  raw = {
    raw: "rules:\n  - DOMAIN-SUFFIX,cloud.microsoft,Microsoft\n  - MATCH,Default\n",
    rules: [' DOMAIN-SUFFIX, cloud.microsoft, Microsoft ', 'MATCH,Default'],
    groups: [{ 'name' => 'Microsoft' }, { 'name' => 'Default' }]
  }
  summary = config_summary(raw)
  fail_safely('rule comparison self-test failed') unless summary[:cloud_count] == 1
  fail_safely('rule comparison self-test failed') unless summary[:cloud_target_exists]
  fail_safely('rule comparison self-test failed') unless summary[:cloud_before_match]
  fail_safely('rule comparison self-test failed') unless summary[:match_is_last]
  fail_safely('rule comparison self-test failed') unless multiset_shared_count(['a', 'a'], ['a']) == 1

  puts('self_test_cases=5')
  puts('self_test_passed=true')
end

if ARGV == ['self-test']
  self_test
  exit
end
fail_safely('usage: compare_profile_effective_rules.rb [self-test]') unless ARGV.empty?

raw_summary = config_summary(load_config(RAW_PROFILE_PATH, 'raw profile'))
effective_summary = config_summary(load_config(EFFECTIVE_CONFIG_PATH, 'effective config'))
shared_count = multiset_shared_count(
  raw_summary[:canonical_rules],
  effective_summary[:canonical_rules]
)
first_divergence = raw_summary[:canonical_rules].zip(
  effective_summary[:canonical_rules]
).find_index { |left, right| left != right }

puts('raw_yaml_parse_ok=true')
puts('effective_yaml_parse_ok=true')
puts("raw_file_sha256=#{raw_summary[:file_fingerprint]}")
puts("effective_file_sha256=#{effective_summary[:file_fingerprint]}")
puts("raw_rule_count=#{raw_summary[:rule_count]}")
puts("effective_rule_count=#{effective_summary[:rule_count]}")
puts("raw_non_string_rule_count=#{raw_summary[:non_string_rule_count]}")
puts("effective_non_string_rule_count=#{effective_summary[:non_string_rule_count]}")
puts("raw_rule_order_sha256=#{raw_summary[:order_fingerprint]}")
puts("effective_rule_order_sha256=#{effective_summary[:order_fingerprint]}")
puts("rules_sequence_equal=#{raw_summary[:canonical_rules] == effective_summary[:canonical_rules]}")
puts("rules_multiset_equal=#{shared_count == raw_summary[:canonical_rules].length && shared_count == effective_summary[:canonical_rules].length}")
puts("shared_rule_occurrences=#{shared_count}")
puts("raw_only_rule_occurrences=#{raw_summary[:canonical_rules].length - shared_count}")
puts("effective_only_rule_occurrences=#{effective_summary[:canonical_rules].length - shared_count}")
puts("first_rule_divergence_index=#{first_divergence || 'none'}")
puts("raw_cloud_microsoft_rule_count=#{raw_summary[:cloud_count]}")
puts("effective_cloud_microsoft_rule_count=#{effective_summary[:cloud_count]}")
puts("raw_cloud_microsoft_com_rule_count=#{raw_summary[:wrong_cloud_count]}")
puts("effective_cloud_microsoft_com_rule_count=#{effective_summary[:wrong_cloud_count]}")
puts("raw_cloud_target_exists=#{raw_summary[:cloud_target_exists]}")
puts("effective_cloud_target_exists=#{effective_summary[:cloud_target_exists]}")
puts("cloud_target_same=#{raw_summary[:cloud_target] == effective_summary[:cloud_target]}")
puts("raw_cloud_before_match=#{raw_summary[:cloud_before_match]}")
puts("effective_cloud_before_match=#{effective_summary[:cloud_before_match]}")
puts("raw_match_count=#{raw_summary[:match_count]}")
puts("effective_match_count=#{effective_summary[:match_count]}")
puts("raw_match_is_last=#{raw_summary[:match_is_last]}")
puts("effective_match_is_last=#{effective_summary[:match_is_last]}")
