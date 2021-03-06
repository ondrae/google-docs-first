# Copyright 2015, Google, Inc.
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#    http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

require "google/cloud/datastore"
require "google/cloud/storage"
require "google/cloud/vision"


class Book
  def self.storage_bucket
    @storage_bucket ||= begin
      config = Rails.application.config.x.settings
      storage = Google::Cloud::Storage.new project_id: config["project_id"],
                                           credentials: config["keyfile"]
      storage.bucket config["gcs_bucket"]
    end
  end

  include ActiveModel::Model
  include ActiveModel::Validations

  attr_accessor :id, :description, :image_url, :cover_image

  # Return a Google::Cloud::Datastore::Dataset for the configured dataset.
  # The dataset is used to create, read, update, and delete entity objects.
  def self.dataset
    @dataset ||= Google::Cloud::Datastore.new(
      project_id: Rails.application.config.
                        database_configuration[Rails.env]["dataset_id"]
    )
  end

  # Query Book entities from Cloud Datastore.
  #
  # returns an array of Book query results and a cursor
  # that can be used to query for additional results.
  def self.query options = {}
    query = Google::Cloud::Datastore::Query.new
    query.kind "Book"
    query.limit options[:limit]   if options[:limit]
    query.cursor options[:cursor] if options[:cursor]

    results = dataset.run query
    books   = results.map {|entity| Book.from_entity entity }

    if options[:limit] && results.size == options[:limit]
      next_cursor = results.cursor
    end

    return books, next_cursor
  end

  def self.from_entity entity
    book = Book.new
    book.id = entity.key.id
    entity.properties.to_hash.each do |name, value|
      book.send "#{name}=", value if book.respond_to? "#{name}="
    end
    book
  end

  # Lookup Book by ID.  Returns Book or nil.
  def self.find id
    query    = Google::Cloud::Datastore::Key.new "Book", id.to_i
    entities = dataset.lookup query

    from_entity entities.first if entities.any?
  end

  def save
    if valid?
      entity = to_entity
      Book.dataset.save entity
      self.id = entity.key.id
      update_image if cover_image.present?
      true
    else
      false
    end
  end

  def to_entity
    entity = Google::Cloud::Datastore::Entity.new
    entity.key = Google::Cloud::Datastore::Key.new "Book", id
    entity["image_url"]    = image_url    if image_url
    entity["description"]    = description    if description
    entity
  end

  def update attributes
    attributes.each do |name, value|
      send "#{name}=", value
    end
    save
  end

  def destroy
    delete_image if image_url.present?

    Book.dataset.delete Google::Cloud::Datastore::Key.new "Book", id
  end

  def persisted?
    id.present?
  end

  def upload_image
    file = Book.storage_bucket.create_file \
      cover_image.tempfile,
      "cover_images/#{id}/#{cover_image.original_filename}",
      content_type: cover_image.content_type,
      acl: "public"

    self.image_url = file.public_url

    Book.dataset.save to_entity
  end

  def delete_image
    image_uri = URI.parse image_url.gsub(" ", "%20")

    if image_uri.host == "#{Book.storage_bucket.name}.storage.googleapis.com"
      # Remove leading forward slash from image path
      # The result will be the image key, eg. "cover_images/:id/:filename"
      image_path = image_uri.path.sub("/", "")

      file = Book.storage_bucket.file image_path
      file.delete
    end
  end

  def update_image
    delete_image if image_url.present?
    upload_image
  end

  def analyze
    image_annotator = Google::Cloud::Vision::ImageAnnotator.new

    response = image_annotator.text_detection(
      image: image_url,
      max_results: 1 # optional, defaults to 10
    )

    ocr_text = []
    response.responses.each do |res|
      res.text_annotations.each do |text|
        ocr_text.push text.description
      end
    end

    parsed_description = {}
    fn_index = ocr_text.index("FN") + 1
    parsed_description["First Name:"] = ocr_text[fn_index]
    ln_index = ocr_text.index("LN") + 1
    parsed_description["Last Name:"] = ocr_text[ln_index]

    self.description = ocr_text.flatten

    Book.dataset.save to_entity
  end

end
