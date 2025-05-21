#!/usr/bin/env ruby
# frozen_string_literal: true

require 'httparty'
require 'tmpdir'
require 'fileutils'
require 'shellwords'
require 'json'
require 'optparse'

def extract_audio(video_path, output_audio_path)
  command = "ffmpeg -i #{Shellwords.escape(video_path)} " \
    "-vn -acodec libopus -b:a 64k #{Shellwords.escape(output_audio_path)} -y"
  puts 'Extracting audio from the video...'
  system(command) || raise('Failed to extract audio')
end

def split_audio(audio_path, chunk_dir, chunk_duration = 300)
  puts "Splitting audio into #{chunk_duration / 60} minute chunks..."
  command = "ffmpeg -i #{Shellwords.escape(audio_path)} -f segment -segment_time #{chunk_duration} " \
    "-c copy #{Shellwords.escape(File.join(chunk_dir, 'chunk_%03d.ogg'))} -y"
  system(command) || raise('Failed to split audio')
  Dir.glob(File.join(chunk_dir, 'chunk_*.ogg')).sort
end

def transcribe_audio_chunk(audio_path, language)
  audio_file = File.open(audio_path, 'rb')
  response = HTTParty.post(
    'https://api.openai.com/v1/audio/transcriptions',
    headers: {
      'Authorization' => "Bearer #{ENV['OPENAI_API_KEY']}",
      'Content-Type' => 'multipart/form-data'
    },
    body: {
      'file' => audio_file,
      'model' => 'whisper-1',
      'language' => language,
      'response_format' => 'verbose_json',
      'timestamp_granularities' => ['word']
    }
  )

  audio_file.close
  if response.code == 200
    response_body = JSON.parse(response.body)
    response_body
  else
    raise "Failed to transcribe audio chunk: #{response.body}"
  end
end

def transcribe_audio(audio_path, language)
  Dir.mktmpdir do |chunk_dir|
    chunks = split_audio(audio_path, chunk_dir)
    base_offset = 0
    segments = []

    chunks.each do |chunk|
      puts "Transcribing chunk: #{chunk}"
      result = transcribe_audio_chunk(chunk, language)

      # Adjust timestamps for this chunk
      chunk_segments = result['words'].map do |word|
        {
          text: word['word'],
          start: word['start'] + base_offset,
          end: word['end'] + base_offset
        }
      end

      segments.concat(chunk_segments)
      base_offset += 300 # Add chunk duration to offset
    end

    segments
  end
end

def translate_text(text, target_language)
  response = HTTParty.post(
    'https://api.openai.com/v1/chat/completions',
    headers: {
      'Authorization' => "Bearer #{ENV['OPENAI_API_KEY']}",
      'Content-Type' => 'application/json'
    },
    body: {
      'model' => 'gpt-4',
      'messages' => [
        {
          'role' => 'system',
          'content' => "You are a translator. Translate the following text to #{target_language}. Preserve the meaning and tone."
        },
        {
          'role' => 'user',
          'content' => text
        }
      ]
    }.to_json
  )

  if response.code == 200
    JSON.parse(response.body)['choices'][0]['message']['content']
  else
    raise "Failed to translate text: #{response.body}"
  end
end

def create_subtitles(segments, output_srt_path, target_language = nil)
  puts 'Creating SRT subtitles...'

  # Group words into subtitle lines (roughly 10 words per line)
  lines = []
  current_line = []
  current_start = nil

  segments.each do |segment|
    if current_line.empty?
      current_start = segment[:start]
    end

    current_line << segment[:text]

    if current_line.length >= 10 || segment == segments.last
      text = current_line.join(' ')
      translated_text = target_language ? translate_text(text, target_language) : text

      lines << {
        text: translated_text,
        start: current_start,
        end: segment[:end]
      }
      current_line = []
    end
  end

  File.open(output_srt_path, 'w') do |file|
    lines.each_with_index do |line, i|
      file.puts(i + 1)
      file.puts("#{format_timestamp(line[:start])} --> #{format_timestamp(line[:end])}")
      file.puts(line[:text].strip)
      file.puts
    end
  end
end

def format_timestamp(seconds)
  total_millis = (seconds * 1000).to_i
  hrs = total_millis / (3600 * 1000)
  mins = (total_millis / (60 * 1000)) % 60
  secs = (total_millis / 1000) % 60
  ms = total_millis % 1000
  format('%02d:%02d:%02d,%03d', hrs, mins, secs, ms)
end

def add_subtitles_to_video(video_path, srt_paths, output_video_path, target_language = nil)
  # Base: input video and first subtitle
  command = "ffmpeg -i #{Shellwords.escape(video_path)} -i #{Shellwords.escape(srt_paths[0])} "
  # If there's a second subtitle
  command += "-i #{Shellwords.escape(srt_paths[1])} " if target_language

  # Add -map options for video, audio, and both subtitle tracks
  command += "-map 0:v -map 0:a? -map 1 -map 2 " if target_language
  command += "-map 0:v -map 0:a? -map 1 " unless target_language

  # Subtitle codec
  command += "-c:v copy -c:a copy -c:s mov_text "
  # Add language metadata
  command += "-metadata:s:s:0 language=eng "
  command += "-metadata:s:s:1 language=#{target_language} " if target_language

  # Finish
  command += "#{Shellwords.escape(output_video_path)} -y"
  puts 'Adding subtitles to the video...'
  system(command) || raise('Failed to add subtitles to the video')
end

if __FILE__ == $PROGRAM_NAME
  options = {}
  OptionParser.new do |opts|
    opts.banner = "Usage: #{$PROGRAM_NAME} [options]"

    opts.on('-v', '--video VIDEO_PATH', 'Path to video file') do |v|
      options[:video_path] = v
    end

    opts.on('-l', '--language LANGUAGE', 'Language code (default: en)') do |l|
      options[:language] = l
    end

    opts.on('-t', '--translate LANGUAGE', 'Translate subtitles to specified language code') do |t|
      options[:translate_to] = t
    end

    opts.on('-h', '--help', 'Show this help message') do
      puts opts
      exit
    end
  end.parse!

  video_path = options[:video_path]
  language = options[:language] || 'en'
  translate_to = options[:translate_to]

  if video_path.nil?
    puts "Error: Video path is required. Use --help for usage information."
    exit 1
  end

  raise "Video file not found: #{video_path}" unless File.exist?(video_path)

  Dir.mktmpdir do |tmpdir|
    audio_path = File.join(tmpdir, 'audio.ogg')
    srt_path = File.join(tmpdir, 'subtitles.srt')
    translated_srt_path = translate_to ? File.join(tmpdir, 'subtitles_translated.srt') : nil
    transcript_txt_path = File.join(File.dirname(video_path), 'transcription.txt')
    output_video_path = File.join(File.dirname(video_path), 'output_with_subtitles.mp4')

    extract_audio(video_path, audio_path)
    segments = transcribe_audio(audio_path, language)

    # Save the transcript to a text file
    File.write(transcript_txt_path, segments.map { |s| s[:text] }.join(' '))
    puts "Transcript saved as: #{transcript_txt_path}"

    # Create original subtitles
    create_subtitles(segments, srt_path)

    # Create translated subtitles if requested
    if translate_to
      puts "Creating translated subtitles in #{translate_to}..."
      create_subtitles(segments, translated_srt_path, translate_to)
    end

    srt_paths = [srt_path]
    srt_paths << translated_srt_path if translate_to

    add_subtitles_to_video(video_path, srt_paths, output_video_path, translate_to)
    puts "Video with subtitles saved as: #{output_video_path}"
  end
end