class Manager
  def initialize(base_url)
    Octokit.configure do |c|
      c.api_endpoint = base_url
    end
    @octokit = Octokit::Client.new
  end

  def crawl(owner)
    puts "Crawling #{owner}"
    @octokit.repositories(owner).each do |repo_details|
      repo = sync_repo(owner, repo_details.name)
      puts "Crawling #{repo.path}"
      pulls = (@octokit.pull_requests(repo.path) + @octokit.pull_requests(repo.path, 'closed'))
      pulls.each do |pull|
        puts "Crawling #{repo.path} pull #{pull.number}"
        sync_review(repo, pull)
      end
    end
  end

  def sync_repo(owner, name)
    Repo.where(user_id: sync_user(owner).id, name: name).first_or_create
  end

  def sync_review(repo, pull)
    review = repo.reviews.where(pull_number: pull.number).first_or_create
    review.state = pull.state
    review.title = pull.title
    review.due_at = get_due_at(repo, pull)
    review.save!

    comments = @octokit.issue_comments(repo.path, pull.number)
    sync_reviewers(review, pull, comments)
  end

  def sync_reviewers(review, pull, comments)
    pull.body =~ /^Reviewers: (.+)$/
    reviewers_string = "#{$1} #{review.repo.default_reviewers}"
    reviewers_string.split(/[\s,]+/).map do |id|
      next if id.blank?
      login = id.sub('@', '').downcase
      next unless user = sync_user(login) # TODO don't call this as often
      completion = comments.detect {|c| c.body == '+1' && c.user.login.downcase == login}
      reviewer = review.reviewers.where(user_id: user.id).first_or_create
      reviewer.completed_at = (completion.created_at if completion)
      reviewer.save!
    end

    # TODO delete old reviewers?
  end

  def sync_user(login)
    github_user = @octokit.user(login)
    return nil unless github_user
    user = User.where(login: login).first_or_create
    user.name = github_user.name
    user.image_url = github_user.avatar_url
    user.save!
    user
  end

  def get_due_at(repo, pull)
    # This is bad and I feel bad
    # but I think it's good enough for the moment
    # maybe
    from = DateTime.iso8601(pull.created_at).new_offset('CST') # FIXME

    pull.body =~ /^Due: (.+)\s*$/
    return DateUtil.parse(from, $1.chomp) if $1
    repo.default_due_at(from)
  rescue => ex
    puts ex
    nil
  end
end