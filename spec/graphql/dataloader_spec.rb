# frozen_string_literal: true
require "spec_helper"

describe "GraphQL::Dataloader" do
  module DataloaderTest
    module Backend
      LOG = []
      DEFAULT_DATA = {
        "b1" => { title: "Remembering", author_id: "a1" },
        "b2" => { title: "That Distant Land", author_id: "a1" },
        "b3" => { title: "Doggies", author_id: "a2" },
        "b4" => { title: "The Cloud of Unknowing", author_id: "a3" }, # This author intentionally missing
        "a1" => { name: "Wendell Berry", book_ids: ["b1", "b2"] },
        "a2" => { name: "Sandra Boynton", book_ids: ["b3"] },
      }.freeze

      def self.reset
        self.data = DEFAULT_DATA.dup
      end

      class << self
        attr_accessor :data
      end

      def self.mget(keys)
        LOG << "MGET #{keys}"
        keys.map { |k| self.data[k] || raise("Key not found: #{k}") }
      end

      def self.set(id, object)
        self.data[id] = object
      end
    end

    class BackendLoader < GraphQL::Dataloader::Loader
      def self.load_object(ctx, id)
        load(ctx, nil, id)
      end

      def perform(ids)
        ids = ids.sort # for stable logging
        Backend.mget(ids).each_with_index do |item, idx|
          fulfill(ids[idx], item)
        end
      end
    end

    class Schema < GraphQL::Schema
      class Author < GraphQL::Schema::Object
        field :name, String, null: false
        field :books, [GraphQL::Schema::LateBoundType.new("Book")], null: false

        def books
          BackendLoader.load_all(context, nil, object[:book_ids])
        end
      end

      class Book < GraphQL::Schema::Object
        field :title, String, null: false
        field :author, Author, null: false

        def author
          BackendLoader.load_object(context, object[:author_id])
        end
      end

      class Query < GraphQL::Schema::Object
        field :book, Book, null: true do
          argument :id, ID, required: true
        end

        def book(id:)
          BackendLoader.load_object(@context, id)
        end

        field :author, Author, null: true do
          argument :id, ID, required: true
        end

        def author(id:)
          BackendLoader.load_object(@context, id)
        end

        field :books_count, Integer, null: false do
          argument :author_id, ID, required: true
        end

        def books_count(author_id:)
          # Of course this could be done without a nested load, but I want to test nested loaders
          BackendLoader.load_object(@context, author_id).then do |author|
            BackendLoader.load_all(@context, nil, author[:book_ids]).then do |books|
              books.size
            end
          end
        end
      end

      class Mutation < GraphQL::Schema::Object
        field :add_author, Author, null: true do
          argument :id, ID, required: true
          argument :name, String, required: true
          argument :book_ids, [ID], required: true
        end

        def add_author(id:, name:, book_ids:)
          author = { name: name, book_ids: book_ids }
          Backend.set(id, author)
          author
        end
      end

      query(Query)
      mutation(Mutation)
      use GraphQL::Execution::Interpreter
      use GraphQL::Analysis::AST
      use GraphQL::Dataloader
    end
  end

  def exec_query(*args)
    DataloaderTest::Schema.execute(*args)
  end

  let(:log) { DataloaderTest::Backend::LOG }

  before do
    DataloaderTest::Backend.reset
    log.clear
  end

  it "batches requests" do
    res = exec_query('{
      b1: book(id: "b1") { title author { name } }
      b2: book(id: "b2") { title author { name } }
    }')

    assert_equal "Remembering", res["data"]["b1"]["title"]
    assert_equal "Wendell Berry", res["data"]["b1"]["author"]["name"]
    assert_equal "That Distant Land", res["data"]["b2"]["title"]
    assert_equal "Wendell Berry", res["data"]["b2"]["author"]["name"]
    assert_equal ['MGET ["b1", "b2"]', 'MGET ["a1"]'], log
  end

  it "batches requests across branches of a query" do
    exec_query('{
      a1: author(id: "a1") { books { title } }
      a2: author(id: "a2") { books { title } }
    }')

    expected_log = [
      "MGET [\"a1\", \"a2\"]",
      "MGET [\"b1\", \"b2\", \"b3\"]"
    ]
    assert_equal expected_log, log
  end

  it "doesn't load the same object over again" do
    exec_query('{
      b1: book(id: "b1") {
        title
        author { name }
      }
      a1: author(id: "a1") {
        books {
          author {
            books {
              title
            }
          }
        }
      }
    }')

    expected_log = [
      'MGET ["a1", "b1"]',
      'MGET ["b2"]'
    ]
    assert_equal expected_log, log
  end

  it "shares over a multiplex" do
    query_string = "query($id: ID!) { author(id: $id) { name } }"
    results = DataloaderTest::Schema.multiplex([
      { query: query_string, variables: { "id" => "a1" } },
      { query: query_string, variables: { "id" => "a2" } },
    ])

    assert_equal "Wendell Berry", results[0]["data"]["author"]["name"]
    assert_equal "Sandra Boynton", results[1]["data"]["author"]["name"]
    assert_equal ["MGET [\"a1\", \"a2\"]"], log
  end

  it "doesn't batch between mutations" do
    query_str = <<-GRAPHQL
      mutation {
        add1: addAuthor(id: "a3", name: "Beatrix Potter", bookIds: ["b1", "b2"]) {
          books {
            title
          }
        }
        add2: addAuthor(id: "a4", name: "Joel Salatin", bookIds: ["b1", "b3"]) {
          books {
            title
          }
        }
      }
    GRAPHQL

    exec_query(query_str)
    expected_log = ['MGET ["b1", "b2"]', 'MGET ["b1", "b3"]']
    assert_equal expected_log, log
  end

  it "works with nested loaders" do
    query_str = <<-GRAPHQL
    {
      a1: booksCount(authorId: "a1")
      a2: booksCount(authorId: "a2")
    }
    GRAPHQL

    res = exec_query(query_str)
    assert_equal({"data"=>{"a1"=>2, "a2"=>1}}, res)
    expected_log = [
      'MGET ["a1", "a2"]',
      'MGET ["b1", "b2", "b3"]',
    ]
    assert_equal expected_log, log
  end

  it "raises helpful errors" do
    err = assert_raises GraphQL::Dataloader::LoadError do
      exec_query('query GetBook { book4: book(id: "b4") { author { name } } }')
    end
    assert_equal "Key not found: a3", err.cause.message
    assert_equal "Error from DataloaderTest::BackendLoader#perform(\"a3\") at GetBook.book4.author", err.message
    assert_equal ["book4", "author"], err.graphql_path
  end
end
