#!/usr/bin/env ruby
# encoding: UTF-8

APP_ROOT = File.dirname(__FILE__) + "/../"
ENV["BUNDLE_GEMFILE"] = APP_ROOT + "Gemfile"
$:.unshift APP_ROOT + "/lib"

require "bundler"
Bundler.setup(:default)
require "logger"
require "active_record"
require "biribiri"
require "chronic"
require "transmission_api"
include Biribiri

# Load options from config and ARGV
opts = Options.new
begin 
	opts.load_config(APP_ROOT + "/config.yaml")
rescue Exception => e
	puts e.message
	exit
end
options = opts.options
Logger.setup(options)
Logger.log.info("Radio Noise (欠陥電気) starting up.")

options[:backlog][:set] = Chronic.parse(options[:radionoise][:backlog])

STATUS_MAP = {
	0 => "stopped",
	1 => "check pending",
	2 => "checking",
	3 => "download pending",
	4 => "downloading",
	5 => "seed pending",
	6 => "seeding"
}

GLOB_FILETYPES = "mkv,avi,mp4"

Logger.log.level = options[:logging][:level]

railgun = Railgun.new(options)

tc = TransmissionApi.new(
	:username => options[:transmission][:username],
	:password => options[:transmission][:password],
	:url => options[:transmission][:url])

tc.fields.push("hashString", "status", "percentDone", "downloadDir")
tc.fields.delete("files")

Logger.log.info("Transmission to #{options[:transmission][:url]}")

Logger.log.debug "Connecting to Database"
# Connect to database
ActiveRecord::Base.establish_connection(options[:database])
ActiveRecord::Base.logger = Logger.log

# Some documentation about transmission
# percentDone => double (1 if files are transferred)
# status => number (see status_map)
# isFinished => boolean (has reached ratio limit)

require "commander/import"
program :name, "radionoise"
program :description, "The post-processing script for dealing with torrents"
program :version, Biribiri::VERSION

global_option("--loglevel [LEVEL]", Options::DEBUG_MAP.keys, "Sets logging to LEVEL") do |level|
	Logger.log.level = Options::DEBUG_MAP[level]
	Logger.log.debug "DEBUGGING ONLINE!"
end

command :add do |c|
	c.syntax = "radionoise.rb add [torrenthash]"
	c.description = "Post-processing from transmission. $TR_TORRENT_HASH can be used in place of [torrenthash]"
	c.action do |args, cops|
		# Get information on torrent from hash
		thash = (ENV["TR_TORRENT_HASH"] or options[0])
		unless thash
			Logger.log.fatal("You must pass a hash in $TR_TORRENT_HASH or as a parameter.")
			railgun.teardown
			exit(1)
		end

		torrent = tc.find(thash)
		unless torrent
			Logger.log.fatal("Torrent Hash #{thash} not found")
			railgun.teardown
			exit(1)
		end

		# Check if the Hash is Anime (based on path, set in config)
		if torrent["downloadDir"].scan(/anime/).empty?
			Logger.log.fatal("Torrent #{torrent["name"]} is not anime")
			railgun.teardown
			exit(1)
		end

		# Copy the file to "Unsorted" folder
		fullpath = torrent["downloadDir"] + "/" + torrent["name"]
		FileUtils.cp_r(fullpath, options[:renamer][:unsorted])
		Logger.log.info("Copied #{fullpath} to #{options[:renamer][:unsorted]}")	

		# Glob and run "Railgun" on it
		Logger.log.info("Running Railgun on Torrent")
		globpath = "#{options[:renamer][:unsorted]}/#{torrent["name"]}"
		globpath.gsub!(/([\[\]\{\}\*\?\\])/, '\\\\\1')
		allglob = Dir.glob(globpath, File::FNM_CASEFOLD) + Dir.glob(globpath + "/**/*.{#{GLOB_FILETYPES}}", File::FNM_CASEFOLD)
		files = allglob.select { |f| File.file?(f) }
		railgun.process(files)

		# Add hash to torrents tabled, marking copied = true
		Logger.log.info("Marking torrent as done")
		dbrow = Torrents.where(hash_string: torrent["hashString"]).first_or_create
		dbrow.name = torrent["name"]
		dbrow.copied = true
		dbrow.save
		railgun.teardown
		Logger.log.info("Radio Noise (欠陥電気) is done! Shutting down. ビリビリ.")
	end
end

command :cron do |c|
	c.syntax = "radionoise.rb cron"
	c.description = "Processes old torrents and unsorted folder"
	c.action do |args, cops|
		# Run Railgun on all video files in "Unsorted" folder (this catches files never had info)
		Logger.log.info("Processing #{options[:renamer][:unsorted]}")
		globpath = options[:renamer][:unsorted]
		globpath.gsub!(/([\[\]\{\}\*\?\\])/, '\\\\\1')
		files = Dir.glob(globpath + "/**/*.{#{GLOB_FILETYPES}}", File::FNM_CASEFOLD).select { |f| File.file?(f) }
		railgun.process(files)

		# Delete any torrent that's "completed" and "copied"
		Logger.log.info("Deleting \"completed\" and \"copied\" torrents")
		completedtorrents = tc.all.select do |torrent|
			(torrent["isFinished"] == true or torrent["status"] == 0) and not torrent["downloadDir"].scan(/anime/).empty?
		end
		completedtorrents.each do |torrent|
			Logger.log.debug("Prepping to remove #{torrent["name"]} (#{torrent["hashString"]}) at #{torrent["downloadDir"]}")
			trow = Torrents.find_by hash_string: torrent["hashString"]
			if trow and trow.copied?
				Logger.log.info("Removed #{torrent["downloadDir"]}/#{torrent["name"]}")
				begin
					FileUtils.rm_r("#{torrent["downloadDir"]}/#{torrent["name"]}")
				rescue
					Logger.log.info("#{torrent["downloadDir"]}/#{torrent["name"]} not found. Assuming gone.")
				end

				# Remove hash from database so torrent can be redownloaded again
				Logger.log.info("Removed #{torrent["hashString"]} from database")
				trow.destroy
			end
		end
		railgun.teardown
		Logger.log.info("Radio Noise (欠陥電気) is done! Shutting down. ビリビリ.")
	end
end


