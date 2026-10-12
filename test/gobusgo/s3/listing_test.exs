defmodule Gobusgo.S3.ListingTest do
  # Parses listing bodies written as S3 documents them and observes the keys
  # and the continuation token returned, and the refusal of each body that
  # is no listing.
  use ExUnit.Case, async: true

  alias Gobusgo.S3.Listing

  defp body(inner) do
    ~s(<?xml version="1.0" encoding="UTF-8"?>) <>
      ~s(<ListBucketResult xmlns="http://s3.amazonaws.com/doc/2006-03-01/">) <>
      inner <> "</ListBucketResult>"
  end

  defp contents(key), do: "<Contents><Key>#{key}</Key><Size>3</Size></Contents>"

  describe "parse/1" do
    test "returns the keys in the order the body lists them" do
      xml = body("<IsTruncated>false</IsTruncated>" <> contents("a/1") <> contents("a/2"))

      assert Listing.parse(xml) == {:ok, %{keys: ["a/1", "a/2"], continuation_token: nil}}
    end

    test "returns no keys for a listing that matches nothing" do
      xml = body("<KeyCount>0</KeyCount><IsTruncated>false</IsTruncated>")

      assert Listing.parse(xml) == {:ok, %{keys: [], continuation_token: nil}}
    end

    test "returns the continuation token of a truncated listing" do
      xml =
        body(
          "<IsTruncated>true</IsTruncated>" <>
            "<NextContinuationToken>1ueGcx/XY=</NextContinuationToken>" <> contents("a/1")
        )

      assert Listing.parse(xml) == {:ok, %{keys: ["a/1"], continuation_token: "1ueGcx/XY="}}
    end

    test "decodes a key the body holds percent-encoded" do
      xml = body("<IsTruncated>false</IsTruncated>" <> contents("raw/dt%3D2026-10-02/a%20b"))

      assert Listing.parse(xml) ==
               {:ok, %{keys: ["raw/dt=2026-10-02/a b"], continuation_token: nil}}
    end

    for {name, xml} <- [
          {"a body that is not XML", "not xml"},
          {"an empty body", ""},
          {"another root element", "<Error><Code>AccessDenied</Code></Error>"},
          {"a listing without IsTruncated",
           ~s(<ListBucketResult><Contents><Key>a</Key></Contents></ListBucketResult>)},
          {"a truncated listing without a token",
           ~s(<ListBucketResult><IsTruncated>true</IsTruncated></ListBucketResult>)},
          {"a body with a document type",
           ~s(<!DOCTYPE a [<!ENTITY b "c">]><ListBucketResult><IsTruncated>false</IsTruncated></ListBucketResult>)}
        ] do
      test "refuses #{name}" do
        assert Listing.parse(unquote(xml)) == {:error, :malformed}
      end
    end
  end

  describe "error_code/1" do
    test "returns the code of an error body" do
      xml = "<Error><Code>NoSuchKey</Code><Message>The key does not exist.</Message></Error>"

      assert Listing.error_code(xml) == {:ok, "NoSuchKey"}
    end

    test "returns :error for a body that is no error document" do
      assert Listing.error_code("") == :error
    end
  end
end
