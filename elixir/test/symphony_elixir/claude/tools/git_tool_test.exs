defmodule SymphonyElixir.Claude.Tools.GitToolTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Claude.Tools.GitTool

  defp setup_git_workspace do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-git-tool-#{System.unique_integer([:positive])}"
      )

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

    {test_root, workspace}
  end

  test "git_status returns branch and file status" do
    write_workflow_file!(Workflow.workflow_file_path(), git_enabled: true)

    {test_root, workspace} = setup_git_workspace()

    try do
      # Create an unstaged change
      File.write!(Path.join(workspace, "new_file.txt"), "content\n")

      response = GitTool.execute("git_status", %{}, workspace: workspace)

      assert response["success"] == true
      [%{"text" => text}] = response["contentItems"]
      status = Jason.decode!(text)

      assert status["branch"] == "main"
      assert "new_file.txt" in status["untracked"]
    after
      File.rm_rf(test_root)
    end
  end

  test "git_status shows staged files" do
    write_workflow_file!(Workflow.workflow_file_path(), git_enabled: true)

    {test_root, workspace} = setup_git_workspace()

    try do
      File.write!(Path.join(workspace, "staged.txt"), "staged\n")
      System.cmd("git", ["-C", workspace, "add", "staged.txt"])

      response = GitTool.execute("git_status", %{}, workspace: workspace)

      assert response["success"] == true
      [%{"text" => text}] = response["contentItems"]
      status = Jason.decode!(text)

      assert "staged.txt" in status["staged"]
    after
      File.rm_rf(test_root)
    end
  end

  test "git_commit stages all and creates commit" do
    write_workflow_file!(Workflow.workflow_file_path(), git_enabled: true)

    {test_root, workspace} = setup_git_workspace()

    try do
      File.write!(Path.join(workspace, "feature.txt"), "feature\n")

      response =
        GitTool.execute("git_commit", %{"message" => "add feature"}, workspace: workspace)

      assert response["success"] == true
      [%{"text" => text}] = response["contentItems"]
      result = Jason.decode!(text)
      assert result["message"] == "Commit created"

      # Verify the commit exists
      {log, 0} = System.cmd("git", ["-C", workspace, "log", "--oneline", "-1"])
      assert log =~ "add feature"
    after
      File.rm_rf(test_root)
    end
  end

  test "git_commit with specific files" do
    write_workflow_file!(Workflow.workflow_file_path(), git_enabled: true)

    {test_root, workspace} = setup_git_workspace()

    try do
      File.write!(Path.join(workspace, "include.txt"), "yes\n")
      File.write!(Path.join(workspace, "exclude.txt"), "no\n")

      response =
        GitTool.execute(
          "git_commit",
          %{"message" => "only include", "files" => ["include.txt"]},
          workspace: workspace
        )

      assert response["success"] == true

      # Verify exclude.txt is still untracked
      {status, 0} = System.cmd("git", ["-C", workspace, "status", "--porcelain"])
      assert status =~ "?? exclude.txt"
      refute status =~ "include.txt"
    after
      File.rm_rf(test_root)
    end
  end

  test "git_commit rejects empty message" do
    write_workflow_file!(Workflow.workflow_file_path(), git_enabled: true)

    response =
      GitTool.execute("git_commit", %{"message" => "   "}, workspace: "/tmp")

    assert response["success"] == false
    [%{"text" => text}] = response["contentItems"]
    assert Jason.decode!(text)["error"]["message"] =~ "non-empty"
  end

  test "git_commit with nothing to commit returns success message" do
    write_workflow_file!(Workflow.workflow_file_path(), git_enabled: true)

    {test_root, workspace} = setup_git_workspace()

    try do
      response =
        GitTool.execute("git_commit", %{"message" => "no changes"}, workspace: workspace)

      assert response["success"] == true
      [%{"text" => text}] = response["contentItems"]
      result = Jason.decode!(text)
      assert result["message"] =~ "Nothing to commit"
    after
      File.rm_rf(test_root)
    end
  end

  test "enabled? returns false when git is disabled" do
    write_workflow_file!(Workflow.workflow_file_path(), git_enabled: false)
    refute GitTool.enabled?()
  end

  test "enabled? returns true when git is enabled" do
    write_workflow_file!(Workflow.workflow_file_path(), git_enabled: true)
    assert GitTool.enabled?()
  end
end
