# This script is used to run erb_lint on the files that have changed in a pull request
# and then comment on the pull request with the offenses found. It also checks the
# pull request for existing comments and removes them if the offense has been fixed.
# This script is intended to run soley in the context of GitHub Actions on pull requests.
#
# See https://github.com/Shopify/erb_lint
#     https://www.rubydoc.info/gems/erb_lint/0.9.0/index

# Setup

puts "::group::Installing erb_lint gems"
versioned_erb_lint_gems =
  if ENV.fetch("ERB_LINT_GEM_VERSIONS").downcase == "gemfile"
    require "bundler"

    Bundler::LockfileParser.new(Bundler.read_file("Gemfile.lock")).specs
      .select { |spec| spec.name.start_with? "erb_lint" }
      .map { |spec| "#{spec.name}:#{spec.version}" }
  else
    ENV.fetch("ERB_LINT_GEM_VERSIONS").split
  end
gem_install_command = "gem install #{versioned_erb_lint_gems.join(' ')} --no-document --conservative"
puts "Installing gems with:", gem_install_command
system "time #{gem_install_command}"
puts "::endgroup::"

# Script

require_relative "lib/github"

# Figure out which erb files have changed and run erb_lint on them

github_event = JSON.parse(File.read(ENV.fetch("GITHUB_EVENT_PATH")))
pr_number = github_event.fetch("pull_request").fetch("number")
owner_and_repository = ENV.fetch("GITHUB_REPOSITORY")

changed_erb_files = Github.pull_request_erb_files(owner_and_repository, pr_number)

# JSON reference, run:
# erb_lint --format json foobar.erb
files_with_offenses =
  if changed_erb_files.any?
    command = "erb_lint #{changed_erb_files.map(&:path).join(' ')} --format json #{ARGV.join(' ')}"

    puts "Running erb_lint with: #{command}"
    JSON.parse(`#{command}`).fetch("files")
  else
    puts "No changed .erb files, skipping erb_lint"

    []
  end

# Fetch existing pull request comments

puts "Fetching PR comments from https://api.github.com/repos/#{owner_and_repository}/pulls/#{pr_number}/comments"

existing_comments = Github.get!("/repos/#{owner_and_repository}/pulls/#{pr_number}/comments")

comments_made_by_erb_lint = existing_comments.select do |comment|
  comment.fetch("body").include?("erb_lint-comment-id")
end

# Find existing comments which no longer have offenses and delete them

fixed_comments = comments_made_by_erb_lint.reject do |comment|
  files_with_offenses.any? do |file|
    file.fetch("path") == comment.fetch("path") &&
      file.fetch("offenses").any? do |offense|
        offense.fetch("location").fetch("start_line") == comment.fetch("line")
      end
  end
end

fixed_comments.each do |comment|
  comment_id = comment.fetch("id")
  path = comment.fetch("path")
  line = comment.fetch("line")

  puts "Deleting resolved comment #{comment_id} on #{path} line #{line}"

  Github.delete!("/repos/#{owner_and_repository}/pulls/comments/#{comment_id}")
end

# Comment on the pull request with the offenses found

def in_diff?(changed_files, path, line)
  file = changed_files.find { |changed_file| changed_file.path == path }
  file&.changed_lines&.include?(line)
end

offences_outside_diff = []

files_with_offenses.each do |file|
  path = file.fetch("path")
  offenses_by_line = file.fetch("offenses").group_by do |offense|
    offense.fetch("location").fetch("start_line")
  end

  # Group offenses by line number and make a single comment per line
  offenses_by_line.each do |line, offenses|
    puts "Handling #{path} line #{line} with #{offenses.count} offenses"

    message = offenses.map do |offense|
      "#{offense.fetch('linter')}: #{offense.fetch('message')}"
    end.join("\n")

    body = <<~BODY
      <!-- erb_lint-comment-id: #{path}-#{line} -->
      #{message}
    BODY

    # If there is already a comment on this line, update it if necessary.
    # Otherwise create a new comment.

    existing_comment = comments_made_by_erb_lint.find do |comment|
      comment.fetch("body").include?("erb_lint-comment-id: #{path}-#{line}")
    end

    if existing_comment
      comment_id = existing_comment.fetch("id")

      # No need to do anything if the offense already exists and hasn't changed
      if existing_comment.fetch("body") == body
        puts "Skipping unchanged comment #{comment_id} on #{path} line #{line}"
        next
      end

      puts "Updating comment #{comment_id} on #{path} line #{line}"
      Github.patch("/repos/#{owner_and_repository}/pulls/comments/#{comment_id}", body: body)
    elsif in_diff?(changed_erb_files, path, line)
      puts "Commenting on #{path} line #{line}"

      # Somehow the commit_id should not be just the HEAD SHA: https://stackoverflow.com/a/71431370/1075108
      commit_id = github_event.fetch("pull_request").fetch("head").fetch("sha")

      Github.post!(
        "/repos/#{owner_and_repository}/pulls/#{pr_number}/comments",
        body: body,
        path: path,
        commit_id: commit_id,
        line: line,
      )
    else
      offences_outside_diff << { path: path, line: line, message: message }
    end
  end
end

# If there are any offenses outside the diff, make a separate comment for them

separate_comments = Github.get!("/repos/#{owner_and_repository}/issues/#{pr_number}/comments")
existing_separate_comment = separate_comments.find do |comment|
  comment.fetch("body").include?("erb_lint-comment-id: outside-diff")
end

if offences_outside_diff.any?
  puts "Found #{offences_outside_diff.count} offenses outside of the diff"

  body = <<~BODY
    <!-- erb_lint-comment-id: outside-diff -->
    Erb Lint offenses found outside of the diff:

  BODY

  body += offences_outside_diff.map do |offense|
    "**#{offense.fetch(:path)}:#{offense.fetch(:line)}**\n#{offense.fetch(:message)}"
  end.join("\n\n")

  if existing_separate_comment
    existing_comment_id = existing_separate_comment.fetch("id")

    # No need to do anything if the offense already exists and hasn't changed
    if existing_separate_comment.fetch("body") == body
      puts "Skipping unchanged separate comment #{existing_comment_id}"
    else
      puts "Updating separate comment #{existing_comment_id}"
      Github.patch!("/repos/#{owner_and_repository}/issues/comments/#{existing_comment_id}", body: body)
    end
  else
    puts "Commenting on pull request with offenses found outside the diff"

    if ENV.fetch("OUTSIDE_DIFF", "true") == "true"
      Github.post!("/repos/#{owner_and_repository}/issues/#{pr_number}/comments", body: body)
    end
  end
elsif existing_separate_comment
  existing_comment_id = existing_separate_comment.fetch("id")
  puts "Deleting resolved separate comment #{existing_comment_id}"
  Github.delete("/repos/#{owner_and_repository}/issues/comments/#{existing_comment_id}")
else
  puts "No offenses found outside of the diff and no existing separate comment to remove"
end

# Fail the build if there were any offenses

number_of_offenses = files_with_offenses.sum { |file| file.fetch("offenses").length }
if number_of_offenses > 0
  puts ""
  puts "#{number_of_offenses} offenses found! Failing the build..."
  exit ENV.fetch("FAILURE_EXIT_CODE", 109).to_i
end
