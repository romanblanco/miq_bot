require 'yaml'

class CommitMonitor
  include Sidekiq::Worker

  def self.options
    @options ||= YAML.load_file(Rails.root.join('config/commit_monitor.yml'))
  end

  def self.product
    @product ||= options["product"]
  end

  def self.handlers
    @handlers ||=
      Dir.glob(Rails.root.join("app/workers/commit_monitor_handlers/*.rb")).collect do |f|
        klass = File.basename(f, ".rb").classify
        CommitMonitorHandlers.const_get(klass)
      end
  end

  delegate :handlers, :to => :class

  def perform
    process_branches
  end

  private

  def process_branches
    CommitMonitorRepo.includes(:branches).each do |repo|
      repo.with_git_service(:debug => true) do |git|
        repo.branches.each { |branch| process_branch(git, branch) }
      end
    end
  end

  def process_branch(git, branch)
    git.checkout branch.name
    git.pull

    commits = find_new_commits(git, branch.last_commit)
    commits.each do |commit|
      message = get_commit_message(git, commit)
      process_commit(branch, commit, message)
    end

    branch.update_attributes(:last_commit => commits.last)
  end

  def find_new_commits(git, last_commit)
    git.rev_list({:reverse => true}, "#{last_commit}..HEAD").chomp.split("\n")
  end

  def get_commit_message(git, commit)
    git.log({:pretty => "fuller"}, "--stat", "-1", commit)
  end

  def process_commit(branch, commit, message)
    handlers.each { |h| h.perform_async(branch.id, commit, message) }
  end
end
