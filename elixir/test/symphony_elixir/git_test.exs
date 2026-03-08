defmodule SymphonyElixir.GitTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Git

  test "branch_name_for_issue generates safe branch names" do
    write_workflow_file!(Workflow.workflow_file_path(), git_enabled: true, git_branch_prefix: "claude/")

    assert Git.branch_name_for_issue("PRJ-123") == "claude/prj-123"
    assert Git.branch_name_for_issue("PRJ/456") == "claude/prj-456"
    assert Git.branch_name_for_issue("My Issue!") == "claude/my-issue-"
  end

  test "branch_name_for_issue respects custom prefix" do
    write_workflow_file!(Workflow.workflow_file_path(), git_enabled: true, git_branch_prefix: "auto/")

    assert Git.branch_name_for_issue("PRJ-123") == "auto/prj-123"
  end

  test "git config defaults when not specified" do
    write_workflow_file!(Workflow.workflow_file_path())

    assert Config.git_enabled?() == false
    assert Config.git_base_branch() == "main"
    assert Config.git_branch_prefix() == "claude/"
    assert Config.git_auto_push?() == true
    assert Config.git_auto_pr?() == true
  end

  test "git config reads enabled state from workflow" do
    write_workflow_file!(Workflow.workflow_file_path(),
      git_enabled: true,
      git_base_branch: "develop",
      git_branch_prefix: "bot/",
      git_auto_push: false,
      git_auto_pr: false
    )

    assert Config.git_enabled?() == true
    assert Config.git_base_branch() == "develop"
    assert Config.git_branch_prefix() == "bot/"
    assert Config.git_auto_push?() == false
    assert Config.git_auto_pr?() == false
  end

  test "setup_branch creates feature branch from base in a real git repo" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-git-setup-#{System.unique_integer([:positive])}"
      )

    try do
      # Create a bare "remote" repo
      remote_repo = Path.join(test_root, "remote.git")
      File.mkdir_p!(remote_repo)
      System.cmd("git", ["init", "--bare", "-b", "main"], cd: remote_repo)

      # Create a working clone (simulates the workspace after after_create hook)
      workspace = Path.join(test_root, "workspace")
      System.cmd("git", ["clone", remote_repo, workspace])
      System.cmd("git", ["-C", workspace, "config", "user.name", "Test"])
      System.cmd("git", ["-C", workspace, "config", "user.email", "test@test.com"])
      File.write!(Path.join(workspace, "README.md"), "hello\n")
      System.cmd("git", ["-C", workspace, "add", "README.md"])
      System.cmd("git", ["-C", workspace, "commit", "-m", "initial"])
      System.cmd("git", ["-C", workspace, "push", "origin", "main"])

      write_workflow_file!(Workflow.workflow_file_path(),
        git_enabled: true,
        git_base_branch: "main",
        git_branch_prefix: "claude/"
      )

      assert :ok = Git.setup_branch(workspace, "PRJ-42")

      # Verify we're on the correct branch
      {branch, 0} = System.cmd("git", ["-C", workspace, "branch", "--show-current"])
      assert String.trim(branch) == "claude/prj-42"

      # Verify the branch contains the base branch content
      assert File.read!(Path.join(workspace, "README.md")) == "hello\n"
    after
      File.rm_rf(test_root)
    end
  end

  test "publish pushes commits and creates branch on remote" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-git-publish-#{System.unique_integer([:positive])}"
      )

    try do
      remote_repo = Path.join(test_root, "remote.git")
      File.mkdir_p!(remote_repo)
      System.cmd("git", ["init", "--bare", "-b", "main"], cd: remote_repo)

      workspace = Path.join(test_root, "workspace")
      System.cmd("git", ["clone", remote_repo, workspace])
      System.cmd("git", ["-C", workspace, "config", "user.name", "Test"])
      System.cmd("git", ["-C", workspace, "config", "user.email", "test@test.com"])
      File.write!(Path.join(workspace, "README.md"), "hello\n")
      System.cmd("git", ["-C", workspace, "add", "README.md"])
      System.cmd("git", ["-C", workspace, "commit", "-m", "initial"])
      System.cmd("git", ["-C", workspace, "push", "origin", "main"])

      write_workflow_file!(Workflow.workflow_file_path(),
        git_enabled: true,
        git_base_branch: "main",
        git_branch_prefix: "claude/",
        git_auto_push: true,
        git_auto_pr: false
      )

      # Setup branch first
      assert :ok = Git.setup_branch(workspace, "PRJ-99")

      # Simulate Claude making a change and committing
      File.write!(Path.join(workspace, "fix.txt"), "fixed\n")
      System.cmd("git", ["-C", workspace, "add", "fix.txt"])
      System.cmd("git", ["-C", workspace, "commit", "-m", "fix: resolve issue"])

      issue = %Issue{
        id: "issue-id",
        identifier: "PRJ-99",
        title: "Fix the bug",
        description: "A bug needs fixing",
        state: "In Progress"
      }

      assert :ok = Git.publish(workspace, "PRJ-99", issue)

      # Verify the branch was pushed to remote
      {refs, 0} = System.cmd("git", ["-C", remote_repo, "branch", "--list"])
      assert refs =~ "claude/prj-99"
    after
      File.rm_rf(test_root)
    end
  end

  test "setup_branch reuses existing local branch" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-git-reuse-#{System.unique_integer([:positive])}"
      )

    try do
      remote_repo = Path.join(test_root, "remote.git")
      File.mkdir_p!(remote_repo)
      System.cmd("git", ["init", "--bare", "-b", "main"], cd: remote_repo)

      workspace = Path.join(test_root, "workspace")
      System.cmd("git", ["clone", remote_repo, workspace])
      System.cmd("git", ["-C", workspace, "config", "user.name", "Test"])
      System.cmd("git", ["-C", workspace, "config", "user.email", "test@test.com"])
      File.write!(Path.join(workspace, "README.md"), "hello\n")
      System.cmd("git", ["-C", workspace, "add", "README.md"])
      System.cmd("git", ["-C", workspace, "commit", "-m", "initial"])
      System.cmd("git", ["-C", workspace, "push", "origin", "main"])

      write_workflow_file!(Workflow.workflow_file_path(),
        git_enabled: true,
        git_base_branch: "main"
      )

      # First setup
      assert :ok = Git.setup_branch(workspace, "PRJ-10")

      # Make a commit on the branch
      File.write!(Path.join(workspace, "work.txt"), "progress\n")
      System.cmd("git", ["-C", workspace, "add", "work.txt"])
      System.cmd("git", ["-C", workspace, "commit", "-m", "wip"])

      # Second setup should keep existing branch and its commits
      assert :ok = Git.setup_branch(workspace, "PRJ-10")

      {branch, 0} = System.cmd("git", ["-C", workspace, "branch", "--show-current"])
      assert String.trim(branch) == "claude/prj-10"
      assert File.exists?(Path.join(workspace, "work.txt"))
    after
      File.rm_rf(test_root)
    end
  end

  test "prompt includes git offload context when enabled" do
    write_workflow_file!(Workflow.workflow_file_path(), git_enabled: true)

    issue = %Issue{
      id: "issue-id",
      identifier: "PRJ-1",
      title: "Test issue",
      description: "A test",
      state: "Todo"
    }

    prompt = PromptBuilder.build_prompt(issue)
    assert prompt =~ "Git Operations — Handled by Infrastructure"
    assert prompt =~ "claude/prj-1"
    assert prompt =~ "Do NOT perform these yourself"
    assert prompt =~ "git add"
    assert prompt =~ "git commit"
  end

  test "prompt does not include git context when disabled" do
    write_workflow_file!(Workflow.workflow_file_path(), git_enabled: false)

    issue = %Issue{
      id: "issue-id",
      identifier: "PRJ-1",
      title: "Test issue",
      description: "A test",
      state: "Todo"
    }

    prompt = PromptBuilder.build_prompt(issue)
    refute prompt =~ "Git Operations — Handled by Infrastructure"
  end
end
