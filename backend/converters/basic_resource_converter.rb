class BasicResourceConverter < Converter

  AUS_date_pat1 = '(\d{1,2}/)?(\d{1,2}/)(\d{4})'
  AUS_date_pat2 = '(\d{1,2}-)?(\d{1,2}-)(\d{4})'

  def self.instance_for(type, input_file)
    if type == "basic_resource"
      self.new(input_file)
    else
      nil
    end
  end


  def self.import_types(show_hidden = false)
    [
      {
        :name => "basic_resource",
        :description => "Paper Collection Sheets CSV"
      }
    ]
  end


  def self.profile
    "Convert a Paper Collection Sheets CSV to ArchivesSpace Resource records"
  end


  def initialize(input_file)
    super
    @batch = ASpaceImport::RecordBatch.new
    @input_file = input_file
    @records = []

    @columns = %w(
                  title
                  resource_id
                  access_conditions
                  use_conditions
                  granted_note
                  processing_note_1
                  processing_note_2
                  date_expression
                  date_begin
                  date_end
                  extent_container_summary
                  extent_number
                  extent_type
                  lang_materials
                  script_materials
                  finding_aid_language
                  finding_aid_script
                  note_conditions_governing_access
                  note_immediate_source_of_acquisition
                  note_arrangement
                  note_biographical_historical
                  note_custodial_history
                  note_general_subjects
                  note_general_archival_history
                  note_general_fa_notes
                  note_physical_description
                  note_preferred_citation
                  note_related_materials
                  note_scope_and_content
                  note_separated_materials
                  note_conditions_governing_use
                  note_bibliography
                  note_existence_and_location_of_copies
                  note_existence_and_location_of_originals
                  note_other_finding_aids
                 )
  end


  def run
    rows = CSV.read(@input_file)

    begin
      while(row = rows.shift)
        values = row_values(row)

        next if values.compact.empty?

        values_map = Hash[@columns.zip(values)]

        # skip header rows, any title containing the string 'resources_basicinformation_title' will be skipped.
        next if values_map['title'].nil? ||
                values_map['title'].strip == '' ||
                values_map['title'] =~ /resources_basicinformation_title/ ||
                values_map['title'] == 'Title'

        create_resource(values_map)
      end
    rescue StopIteration
    end

    # assign all records to the batch importer in reverse
    # order to retain position from spreadsheet
    @records.reverse.each{|record| @batch << record}
  end


  def get_output_path
    output_path = @batch.get_output_path

    p "=================="
    p output_path
    p File.read(output_path)
    p "=================="

    output_path
  end


  private

  def create_resource(row)
    # turns out Emma wants the whole id in id_0
    # leaving this stuff here because, when, you know ...
    # id_a = row['resource_id'].split(/\s+/)
    id_a = [row['resource_id']]
    id_a = id_a + Array.new(4 - id_a.length)
    identifier_json = JSON(id_a)
    finding_aid_language = row['finding_aid_language']
    finding_aid_script = row['finding_aid_script']
    lang_materials = format_lang_material(row)

    uri = "/repositories/12345/resources/import_#{SecureRandom.hex}"

    record_hash = {
                :uri => uri,
                :id_0 => id_a[0],
                :id_1 => id_a[1],
                :id_2 => id_a[2],
                :id_3 => id_a[3],
                :title => row['title'],
                :level => 'collection',
                :repository_processing_note => format_processing_note(row),
                :extents => [format_extent(row, :portion => 'whole')].compact,
                :dates => [format_date(row['date_expression'], row['date_begin'], row['date_end'])].compact,
                :rights_statements => [format_rights_statement(row)].compact,
                :notes => [],
                :finding_aid_language => finding_aid_language,
                :finding_aid_script => finding_aid_script,
                :lang_materials => [lang_materials].compact
    }

    # Add all note fields
    add_notes(record_hash, row)

    @records << JSONModel::JSONModel(:resource).from_hash(record_hash)

  end


  def format_rights_statement(row)
    notes = []
    if row['access_conditions']
      notes << {
        :jsonmodel_type => "note_rights_statement",
        :label => "Access Conditions (eg Available for Reference. Not for Loan)",
        :type => 'additional_information',
        :content => [ row['access_conditions'] ]
      }
    end
    if row['use_conditions']
      notes << {
        :jsonmodel_type => "note_rights_statement",
        :label => "Use Conditions (eg copying not permitted)",
        :type => 'additional_information',
        :content => [ row['use_conditions'] ]
      }
    end
    if row['granted_note']
      notes << {
        :jsonmodel_type => "note_rights_statement",
        :label => "Granted Notes",
        :type => 'additional_information',
        :content => [ row['granted_note'] ]
      }
    end

    {
      :rights_type => 'other',
      :other_rights_basis => 'donor',
      :start_date => Time.now.to_date.iso8601,
      :notes => notes
    }
  end


  def format_processing_note(row)
    [row['processing_note_1'], row['processing_note_2']].compact.join(' ')
  end


  def format_date(date_expression, date_begin, date_end)
    return if date_expression.nil? && date_begin.nil? && date_end.nil?

    {
      :date_type => date_expression =~ /-/ || !(date_begin.nil? || date_end.nil?) ? 'inclusive' : 'single',
      :label => 'creation',
      :expression => date_expression,
      :begin => convert_date_format(date_begin),
      :end => convert_date_format(date_end)
    }
  end

  def format_lang_material(row)
    {
      :language_and_script => JSONModel::JSONModel(:language_and_script).from_hash({
                                                                                     :language => row['lang_materials'],
                                                                                     :script => row['script_materials']
                                                                                   })
    }
  end

  def convert_date_format(date_str)
    if date_str =~ /#{AUS_date_pat1}/ || date_str =~ /#{AUS_date_pat2}/
      $3 + '-' + $2[0..-2] + ($1.nil? ? '' : '-' + $1[0..-2])
    else
      date_str
    end
  end


  def format_extent(row, opts = {})
    return unless row['extent_number'] && row['extent_type']

    {
      :portion => opts.fetch(:portion) { 'part' },
      :extent_type => row['extent_type'],
      :container_summary => row['extent_container_summary'],
      :number => row['extent_number'],
    }
  end


  def add_notes(record_hash, row)
    fields = [['note_conditions_governing_access', 'note_multipart', 'accessrestrict', nil],
              ['note_immediate_source_of_acquisition', 'note_multipart', 'acqinfo', nil],
              ['note_arrangement', 'note_multipart', 'arrangement', nil],
              ['note_biographical_historical', 'note_multipart', 'bioghist', nil],
              ['note_custodial_history', 'note_multipart', 'custodhist', nil],
              ['note_general_subjects', 'note_multipart', 'odd', 'Subjects'],
              ['note_general_archival_history', 'note_multipart', 'odd', 'Archival History'],
              ['note_general_fa_notes', 'note_multipart', 'odd', 'Finding-aid Notes'],
              ['note_physical_description', 'note_singlepart', 'physdesc', nil],
              ['note_preferred_citation', 'note_multipart', 'prefercite', nil],
              ['note_related_materials', 'note_multipart', 'relatedmaterial', nil],
              ['note_scope_and_content', 'note_multipart', 'scopecontent', nil],
              ['note_separated_materials', 'note_multipart', 'separatedmaterial', nil],
              ['note_conditions_governing_use', 'note_multipart', 'userestrict', nil],
              ['note_bibliography', 'note_bibliography', 'bibliography', nil],
              ['note_existence_and_location_of_copies', 'note_multipart', 'altformavail', nil],
              ['note_existence_and_location_of_originals', 'note_multipart', 'originalsloc', nil],
              ['note_other_finding_aids', 'note_multipart', 'otherfindaid', nil]
      ]

      fields.each { |f| add_note(record_hash, row[f[0]], f[1], f[2], f[3])}
  end


  def add_note(record_hash, data, model_type, note_type, note_label)
    if data && (model_type == 'note_multipart' || model_type == 'note_singlepart' || model_type == 'note_bibliography')
      json_rec = {
        :jsonmodel_type => model_type,
        :type => note_type,
      }

      if model_type == 'note_multipart'
        json_rec[:subnotes] = [{
                                :jsonmodel_type => 'note_text',
                                :content => data
                                }]
      else
        json_rec[:content] = [ data ]
      end

      if (note_label)
        json_rec[:label] = note_label
      end

      record_hash[:notes] << json_rec
    end
  end


  def row_values(row)
    (0...row.size).map {|i| row[i] ? row[i].to_s.strip : nil}
  end


  def format_record(row)

    record_hash = {
      :uri => "/repositories/12345/archival_objects/import_#{SecureRandom.hex}",
      :title => row['title'],
      :component_id => row['component_id'],
      :level => format_level(row['level']),
      :dates => [format_date(row['date'])].compact,
      :extents => [format_extent(row)].compact,
      :instances => [format_instance(row)].compact,
      :notes => [],
      :linked_agents => [format_agent(row)].compact,
      :resource => {
        :ref => @resource_uri
      },
    }

    if row['processinfo_note']
      record_hash[:notes] << {
        :jsonmodel_type => 'note_multipart',
        :type => 'processinfo',
        :subnotes =>[{
                       :jsonmodel_type => 'note_text',
                       :content => row['processinfo_note']
                     }]
      }
    end

    record_hash
  end

end
