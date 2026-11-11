defmodule Gobusgo.Places.LicenseTest do
  # Checks the text and the manifest entry of the places file's license as
  # values, since the module is pure.
  use ExUnit.Case, async: true

  alias Gobusgo.Places.License

  describe "notice_text/0" do
    test "names the places file a Derivative Database of OpenStreetMap" do
      assert License.notice_text() =~ "Derivative Database of OpenStreetMap"
    end

    test "offers it under the ODbL 1.0 and links the license" do
      text = License.notice_text()

      assert text =~ "Open Database License 1.0"
      assert text =~ "https://opendatacommons.org/licenses/odbl/1-0/"
    end

    test "credits the contributors and links the copyright page" do
      text = License.notice_text()

      assert text =~ "© OpenStreetMap contributors"
      assert text =~ "https://www.openstreetmap.org/copyright"
    end

    test "names the manifest that names the whole database" do
      assert License.notice_text() =~ "/places/manifest.json"
    end

    test "says the file is free to download" do
      assert License.notice_text() =~ "free to download"
    end

    test "says the file is not under the repository's own license" do
      assert License.notice_text() =~ "not under the license of the Gobusgo repository"
    end

    test "ends with one newline" do
      assert String.ends_with?(License.notice_text(), ".\n")
    end
  end

  describe "manifest_entry/0" do
    test "names the license, its address, the attribution, and the notice's path" do
      assert License.manifest_entry() == %{
               "name" => "ODbL-1.0",
               "uri" => "https://opendatacommons.org/licenses/odbl/1-0/",
               "attribution" => "© OpenStreetMap contributors",
               "attributionUri" => "https://www.openstreetmap.org/copyright",
               "notice" => "places/NOTICE.txt"
             }
    end
  end

  test "notice_destination/0 is the notice's path in the manifest entry" do
    assert License.manifest_entry()["notice"] == License.notice_destination()
  end
end
