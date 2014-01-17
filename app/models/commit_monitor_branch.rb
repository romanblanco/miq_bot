class CommitMonitorBranch < ActiveRecord::Base
  belongs_to :repo, :class_name => :CommitMonitorRepo, :foreign_key => :commit_monitor_repo_id

  validates :name,        :presence => true, :uniqueness => {:scope => :repo}
  validates :commit_uri,  :presence => true
  validates :last_commit, :presence => true
  validates :repo,        :presence => true

  def self.github_commit_uri(user, repo, sha = "$commit")
    "https://github.com/#{user}/#{repo}/commit/#{sha}"
  end

  def commit_uri_to(commit)
    commit_uri.gsub("$commit", commit)
  end

  def last_commit_uri
    commit_uri_to(last_commit)
  end
end
