defmodule Gobusgo.Writer.PosixError do
  @moduledoc """
  The closed mapping from POSIX reasons to `t:Gobusgo.Writer.error_reason/0`.
  Pure; a reason outside the mapping raises, so a new failure mode surfaces
  as a programmer error rather than a silently misfiled outcome.
  """

  alias Gobusgo.Assert

  @doc "Returns the writer error reason for a POSIX reason atom."
  @spec to_reason(atom()) :: Gobusgo.Writer.error_reason()
  def to_reason(:eexist), do: :already_exists
  def to_reason(:eacces), do: :permission_denied
  def to_reason(:eperm), do: :permission_denied
  def to_reason(:enospc), do: :storage_full
  def to_reason(:edquot), do: :storage_full
  def to_reason(:erofs), do: :read_only
  def to_reason(:eio), do: :io_failure
  def to_reason(:enotdir), do: :destination_conflict
  def to_reason(:eisdir), do: :destination_conflict
  def to_reason(:enametoolong), do: {:invalid_destination, :too_long}
  def to_reason(:eloop), do: {:invalid_destination, :symlink}
  def to_reason(other), do: Assert.unreachable!(other)
end
