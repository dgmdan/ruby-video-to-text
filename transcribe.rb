#!/usr/bin/env ruby
# frozen_string_literal: true

require 'httparty'
require 'tmpdir'
require 'fileutils'
require 'shellwords'
require 'json'

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
    raise 'No transcript generated' if response_body['text'].empty?
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

def create_subtitles(segments, output_srt_path)
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
      lines << {
        text: current_line.join(' '),
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

def add_subtitles_to_video(video_path, srt_path, output_video_path)
  command = "ffmpeg -i #{Shellwords.escape(video_path)} -i #{Shellwords.escape(srt_path)} -c:v copy -c:a copy -c:s mov_text -metadata:s:s:0 language=eng #{Shellwords.escape(output_video_path)} -y"
  puts 'Adding subtitles to the video...'
  system(command) || raise('Failed to add subtitles to the video')
end

if __FILE__ == $PROGRAM_NAME
  unless ARGV.length >= 1
    puts "Usage: #{$PROGRAM_NAME} <path_to_video> [language (default: en)]"
    exit 1
  end

  video_path = ARGV[0]
  language = ARGV[1] || 'en'
  raise "Video file not found: #{video_path}" unless File.exist?(video_path)

  Dir.mktmpdir do |tmpdir|
    audio_path = File.join(tmpdir, 'audio.ogg')
    srt_path = File.join(tmpdir, 'subtitles.srt')
    transcript_txt_path = File.join(File.dirname(video_path), 'transcription.txt')
    output_video_path = File.join(File.dirname(video_path), 'output_with_subtitles.mp4')

    extract_audio(video_path, audio_path)
    segments = transcribe_audio(audio_path, language)

    # Save the transcript to a text file
    File.write(transcript_txt_path, segments.map { |s| s[:text] }.join(' '))
    puts "Transcript saved as: #{transcript_txt_path}"

    create_subtitles(segments, srt_path)
    add_subtitles_to_video(video_path, srt_path, output_video_path)
    puts "Video with subtitles saved as: #{output_video_path}"
  end
end