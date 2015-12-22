class CommitMonitorHandlers::CommitRange::RubocopChecker
  include Sidekiq::Worker
  sidekiq_options :queue => :miq_bot

  def self.handled_branch_modes
    [:pr]
  end

  attr_reader :branch, :pr, :commits, :results, :github

  def perform(branch_id, new_commits)
    @branch  = CommitMonitorBranch.where(:id => branch_id).first

    if @branch.nil?
      logger.info("Branch #{branch_id} no longer exists.  Skipping.")
      return
    end
    unless @branch.pull_request?
      logger.info("Branch #{@branch.name} is not a pull request.  Skipping.")
      return
    end

    @pr      = @branch.pr_number
    @commits = @branch.commits_list
    process_branch
  end

  private

  def process_branch
    diff_details = diff_details_for_branch

    unmerged_results = []

    files = filter_ruby_files(diff_details)
    if files.any?
      unmerged_results << linter_results('rubocop', :format => 'json', nil => files)
    end

    files = filter_haml_files(diff_details)
    if files.any?
      unmerged_results << linter_results('haml-lint', :reporter => 'json', nil => files)
    end

    files = filter_css_files(diff_details)
    if files.any?
      unmerged_results << linter_results('scss_lint', :format => 'json', nil => files)
    end

    files = filter_javascript_files(diff_details)
    if files.any?
      unmerged_results << linter_results('jslint-v8', nil => '--json', nil => files)
      unmerged_results << linter_results(asset_path 'jscs.js', :reporter => 'json', nil => files)
    end

    unmerged_results.compact!
    if unmerged_results.empty?
      @results = {"files" => []}
    else
      results = merge_linter_results(*unmerged_results)
      @results = RubocopResultsFilter.new(results, diff_details).filtered
    end

    write_to_github
  end

  def diff_details_for_branch
    MiqToolsServices::MiniGit.call(branch.repo.path) do |git|
      git.diff_details(commits.first, commits.last)
    end
  end

  def filter_ruby_files(diff_details)
    filtered = diff_details.keys.select do |k|
      k.end_with?(".rb") ||
      k.end_with?(".ru") ||
      k.end_with?(".rake") ||
      File.basename(k).in?(%w{Gemfile Rakefile})
    end
    filtered.reject do |k|
      k.end_with?("db/schema.rb")
    end
  end

  def filter_haml_files(diff_details)
    diff_details.keys.select do |k|
      k.end_with?(".haml")
    end
  end

  def filter_css_files(diff_details)
    diff_details.keys.select do |k|
      k.end_with?(".scss")
    end
  end

  def filter_javascript_files(diff_details)
    diff_details.keys.select do |k|
      k.end_with?(".js")
    end
  end

  def linter_results(cmd, options = {})
    require 'awesome_spawn'

    # rubocop exits 1 both when there are errors and when there are style issues.
    #   Instead of relying on just exit_status, we check if there is anything
    #   on stderr.
    result = MiqToolsServices::MiniGit.call(branch.repo.path) do |git|
      git.temporarily_checkout(commits.last) do
        logger.info("#{self.class.name}##{__method__} Executing: #{AwesomeSpawn.build_command_line(cmd, options)}")
        AwesomeSpawn.run(cmd, :params => options, :chdir => branch.repo.path)
      end
    end
    raise result.error if result.exit_status == 1 && result.error.present?

    JSON.parse(result.output.chomp)
  end

  def merge_linter_results(*results)
    return if results.empty?

    new_results = results[0].dup

    results[1..-1].each do |result|
      %w(offense_count target_file_count inspected_file_count).each do |m|
        new_results['summary'][m] += result['summary'][m]
      end
      new_results['files'] += result['files']
    end

    new_results
  end

  def rubocop_comments
    MessageBuilder.new(results, branch).comments
  end

  def write_to_github
    logger.info("#{self.class.name}##{__method__} Updating pull request #{pr} with rubocop comment.")

    branch.repo.with_github_service do |github|
      @github = github
      replace_rubocop_comments
    end
  end

  def replace_rubocop_comments
    github.replace_issue_comments(pr, rubocop_comments) do |old_comment|
      rubocop_comment?(old_comment)
    end
  end

  def rubocop_comment?(comment)
    comment.body.start_with?("<rubocop />")
  end
end
