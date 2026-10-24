#!/usr/bin/env ruby
# Generate tag pages and tag index for Jekyll without plugins

require 'fileutils'
require 'yaml'
require 'date'

# Configuration
POSTS_DIR = '_posts'
TAGS_DIR = 'tags'
LAYOUT = 'tagpage'

# Create tags directory if it doesn't exist
FileUtils.mkdir_p(TAGS_DIR) unless File.directory?(TAGS_DIR)

# Collect all tags from all posts
all_tags = []
Dir.glob(File.join(POSTS_DIR, '*.{md,markdown,html}')).each do |file|
  content = File.read(file)
  if content =~ /^---\s*\n(.*?)\n---\s*\n/m
    frontmatter = YAML.safe_load($1, permitted_classes: [Date, Time])

    if frontmatter && frontmatter['tags']
      tags = frontmatter['tags'].is_a?(Array) ? frontmatter['tags'] : [frontmatter['tags']]
      all_tags.concat(tags.map(&:to_s))
    end
  end
end

# Remove duplicates and sort
all_tags.uniq.sort!

# 1. Generate individual tag pages
all_tags.each do |tag|
  slug = tag.downcase.gsub(/[^a-z0-9]+/, '-').gsub(/^-*|-*$/, '')
  filename = File.join(TAGS_DIR, "#{slug}.html")

  # Skip if file already exists (don't overwrite)
  next if File.exist?(filename)

  File.open(filename, 'w') do |file|
    file.puts "---"
    file.puts "layout: #{LAYOUT}"
    file.puts "tag: #{tag}"
    file.puts "title: \"Tag: #{tag}\""
    file.puts "permalink: /tags/#{slug}/"
    file.puts "---"
    file.puts ""
    file.puts "<!-- This page was auto-generated. Do not edit directly. -->"
  end

  puts "Created: #{filename}"
end

# 2. Generate the Tag Index Page (tags/index.html)
index_filename = File.join(TAGS_DIR, 'index.html')
File.open(index_filename, 'w') do |file|
  file.puts "---"
  file.puts "layout: default"
  file.puts "title: Tags"
  file.puts "permalink: /tags/"
  file.puts "---"
  file.puts ""
  file.puts "<h2>Tag Index</h2>"
  file.puts "<p>Browse posts by subject:</p>"
  file.puts "<hr>"
  file.puts "<ul style=\"list-style-type: none; padding: 0;\">"

  all_tags.each do |tag|
    slug = tag.downcase.gsub(/[^a-z0-9]+/, '-').gsub(/^-*|-*$/, '')
    file.puts "  <li><strong><a href=\"/tags/#{slug}/\">[ #{tag} ]</a></strong></li>"
  end

  file.puts "</ul>"
end

puts "Created: #{index_filename}"
