function [EMAIL_FLAG,LAST_FILE]=intan_frontend_main(DIR,varargin)
%intan_songdet_intmic.m is the core script for processing Intan files
%on the fly.  
%
%	intan_songdet_intmic(DIR,varargin)
%
%	DIR
%	directory to process 
%
%	the following may be specified as parameter/value pairs
%
%
%		minfs
%		minimum fs used for song detection (default: 2e3)
%
%		maxfs
%		maximum fs used for song detection (default: 6e3)
%
%		ratio_thresh
%		ratio between song frequencies and non-song frequencies for song detection (default: 4)
%
%		window
%		spectrogram window for song detection (default: 250 samples)
%		
%		noverlap
%		window overlap for song detection (default: 0)
%
%		song_thresh
%		song threshold (default: .27)
%	
%		songduration
%		song duration for song detection in secs (default: .8 seconds)
%
%		low
%		parameter for spectrogram display (default: 5), lower if spectrogram are dim		
%
%		high
%		parameter for spectrogram display (default: 10)
%
%		colors
%		spectrogram colormap (default: hot)		
%
%		disp_minfs
%		minimum fs for spectrograms (default: 1e3)		
%
%		disp_maxfs
%		maximum fs for spectrograms (default: 7e3)		
%
%		filtering
%		high pass corner for mic trace (default: 700 Hz)
%
%		fs
%		Intan sampling rate (default: 25e3)
%
%		audio_pad
%		extra data to left and right of extraction points to extract (default: .2 secs)
%
%		folder_format
%		folder format (date string) (default: yyyy-mm-dd)
%
%		image_pre
%		image sub directory (default: 'gif')
%	
%		wav_pre
%		wav sub directory (default: 'wav')
%
%		data_pre
%		data sub directory (default: 'mat')
%	
%		delimiter
%		delimiter for filename parsing (default: '\_', or underscore)
%
%		nosort
%		set to 1 to not parse filename (data put into separate folder) (default: 0)
%
%		subdir
%		subdir if nosort==1 (default: 'pretty bird')
%
% see also ephys_pipeline_intmic_daemon.m, song_det.m, im_reformat.m, ephys_pipeline_mkdirs.m
%
%
% To run this in daemon mode, run ephys_pipeline_intmic_daemon.m in the directory with unprocessed Intan
% files.  Be sure to create the appropriate directory structure using epys_pipeline_mkdirs.m first.

% while running the daemon this can be changed 

minfs=2e3; % the song 'band'
maxfs=6e3; % the song 'band'
ratio_thresh=2; % power ratio between song and non-song band
window=250; % window to calculate ratio in (samples)
noverlap=0; % just do no overlap, faster
song_thresh=.2; % between .2 and .3 seems to work best (higher is more exlusive)
pow_thresh=.05; % raw power threshold (so extremely weak signals are excluded)
songduration=.8; % moving average of ratio
low=5;
high=10;
colors='hot';
disp_minfs=1;
disp_maxfs=10e3;
filtering=300; % changed to 100 from 700 as a more sensible default, leave empty to filter later
fs=25e3;
audio_pad=7; % pad on either side of the extraction (in seconds)
error_buffer=5; % if we can't load a file, how many days old before deleting

% parameters for folder creation

folder_format='yyyy-mm-dd';
parse_method='auto'; % auto parse parameters from filename? otherwise MUST provide parameters
		     % through cmdline options
parse_string='auto'; % how to parse filenames, b=birdid, i=recid, m=micid, t=ttlid, d=date
		       % character position indicates which token (after delim split) contains the info

date_string='yymmddHHMMSS'; % parse date using datestr format

% directory names

image_pre='gif';
wav_pre='wav';
data_pre='mat';
sleep_pre='sleep';

delimiter='\_'; % delimiter for splitting fields in filename
bird_delimiter='\&'; % delimiter for splitting multiple birds
subdir='pretty_bird';
sleep_window=[ 22 7 ]; % times for keeping track of sleep data (24 hr time, start and stop)
auto_delete_int=inf; % delete data n days old (set to inf to never delete)
sleep_fileinterval=10; % specify file interval (in minutes) 
sleep_segment=5; % how much data to keep (in seconds)
ttl_skip=0; % skip song detection if TTL detected?

email_monitor=0; % monitor file creation, email if no files created in email_monitor minutes
email_flag=0;
email_noisecut=0;
email_noiselen=4;
file_elapsed=0;


playback_extract=0; % set to 1 if you'd like to extract based on playback
playback_thresh=.01;
playback_rmswin=.025;
playback_skip=0;

% define for manual parsing

ports='';
birdid='';
recid='';
parse_options='';
last_file=clock;

file_check=5; % how long to wait between file reads to check if file is no longer being written (in seconds)

mfile_path = mfilename('fullpath');
[script_path,~,~]=fileparts(mfile_path);

% where to place the parsed files

root_dir=fullfile(pwd,'..','..','intan_data'); % where will the detected files go
proc_dir=fullfile(pwd,'..','processed'); % where do we put the files after processing, maybe auto-delete
					 % after we're confident in the operation of the pipeline
unorganized_dir=fullfile(pwd,'..','unorganized');

hline=repmat('#',[1 80]);

if ~exist(root_dir,'dir')
	mkdir(root_dir);
end

if ~exist(proc_dir,'dir')
	mkdir(proc_dir);
end

% directory for files that have not been recognized

if ~exist(unorganized_dir,'dir');
	mkdir(unorganized_dir);
end

% we should write out a log file with filtering parameters, when we started, whether song was
% detected in certain files, etc.

nparams=length(varargin);

if mod(nparams,2)>0
	error('Parameters must be specified as parameter/value pairs!');
end

for i=1:2:nparams
	switch lower(varargin{i})
		case 'ports'
			ports=varargin{i+1};
		case 'parse_options'
			parse_options=varargin{i+1};
		case 'last_file'
			last_file=varargin{i+1};
		case 'auto_delete_int'
			auto_delete_int=varargin{i+1};
		case 'sleep_window'
			sleep_window=varargin{i+1};
		case 'sleep_fileinterval'
			sleep_fileinterval=varargin{i+1};
		case 'sleep_segment'
			sleep_segment=varargin{i+1};
		case 'filtering'
			filtering=varargin{i+1};
		case 'audio_pad'
			audio_pad=varargin{i+1};
		case 'song_thresh'
			song_thresh=varargin{i+1};
		case 'error_buffer'
			error_buffer=varargin{i+1};
		case 'colors'
			colors=varargin{i+1};
		case 'folder_format'
			folder_format=varargin{i+1};
		case 'delimiter'
			delimiter=varargin{i+1};
		case 'subdir'
			subdir=varargin{i+1};
		case 'ttl_skip'
			ttl_skip=varargin{i+1};
		case 'parse_string'
			parse_string=varargin{i+1};
		case 'email_monitor'
			email_monitor=varargin{i+1};
		case 'email_flag'
			email_flag=varargin{i+1};
		case 'playback_extract'
			playback_extract=varargin{i+1};
		case 'playback_thresh'
			playback_thresh=varargin{i+1};
		case 'playback_rmswin'
			playback_rmswin=varargin{i+1};
		case 'playback_skip'
			playback_skip=varargin{i+1};
		case 'birdid'
			birdid=varargin{i+1};
		case 'recid'
			recid=varargin{i+1};
	end
end

if ~isempty(parse_options)

	if parse_options(end)~=delimiter
		parse_options(end+1)=delimiter;
	end

	if parse_options(1)~=delimiter
		tmp=delimiter;
		tmp(2:length(parse_options)+1)=parse_options;
		parse_options=tmp;
	end

end

if exist('gmail_send')~=2
	disp('Email from MATLAB not figured, turning off auto-email features...');
	email_monitor=0;
end

EMAIL_FLAG=email_flag;
LAST_FILE=last_file;

if nargin<1
	DIR=pwd;
end

% read in int or rhd files

filelisting=dir(fullfile(DIR));

% delete directories

isdir=cat(1,filelisting(:).isdir);
filelisting(isdir)=[];

% read in appropriate suffixes 

filenames={filelisting(:).name};
hits=regexp(filenames,'\.(rhd|int)','match');
hits=cellfun(@length,hits)>0;

filenames(~hits)=[];

proc_files={};
for i=1:length(filenames)
	proc_files{i}=fullfile(DIR,filenames{i});
end

clear filenames;

% check all files in proc directory and delete anything older than 
% auto-delete days

if ~isempty(auto_delete_int)
	auto_delete(proc_dir,auto_delete_int,'rhd');
	auto_delete(proc_dir,auto_delete_int,'int'); 
end

tmp_filelisting=dir(fullfile(DIR));
tmp_filenames={tmp_filelisting(:).name};
tmp_hits=regexp(tmp_filenames,'\.(rhd|int)','match');
tmp_hits=cellfun(@length,tmp_hits)>0;
tmp_filelisting=tmp_filelisting(tmp_hits);
tmp_datenums=cat(1,tmp_filelisting(:).datenum);


if email_monitor>0 & EMAIL_FLAG==0

	if ~isempty(tmp_datenums)
		LAST_FILE=datevec(max(tmp_datenums));
	end

	file_elapsed=etime(clock,LAST_FILE)/60; % time between now and when the last file was created
	disp(['Time since last file created (mins):  ' num2str(file_elapsed)]);

end

if email_monitor>0 & EMAIL_FLAG==0
	if file_elapsed>email_monitor
		gmail_send(['An Intan file has not been created in ' num2str(file_elapsed) ' minutes.']);
		EMAIL_FLAG=1; % don't send another e-mail!
	end
end

user_birdid=birdid;
user_recid=recid;

for i=1:length(proc_files)


	fclose('all'); % seems to be necessary

	% read in the data

	% parse for the bird name,zone and date
	% new folder format, yyyy-mm-dd for easy sorting (on Unix systems at least)	

	disp([repmat(hline,[2 1])]);
	disp(['Processing: ' proc_files{i}]);

	% try reading the file, if we fail, skip

	%%% check if file is still being written to, check byte change within N msec


	% when was the last file created

	dir1=dir(proc_files{i});
	pause(file_check);
	dir2=dir(proc_files{i});

	bytedif=dir1.bytes-dir2.bytes;

	% if we haven't written any new data in the past (file_check) seconds, assume
	% file has been written

	if bytedif==0

		try

			datastruct=intan_frontend_readdata(proc_files{i});
			datastruct.original_filename=proc_files{i};

			if datastruct.filestatus>0 & EMAIL_FLAG==0 & email_monitor>0
				gmail_send(['File reading error, may need to restart the intan_frontend!']);
				EMAIL_FLAG=1; % don't send another e-mail!
			end

		catch err

            		file_datenum=dir2.datenum;
			file_age=daysdif(file_datenum,datenum(now));

			if file_age>error_buffer
				disp(['File too old and cannot process, deleting ' proc_files{i}]);
				delete(proc_files{i});
				continue;
			end

			disp([err])
			disp('Could not read file, continuing...');
			fclose('all'); % read_intan does not properly close file if it bails
			continue;
		end
	else
		disp('File still being written, continuing...');
		continue;
	end


	% if we've defined a noise cutoff, use this to determine if the headstage is connected
	
	nchannels=size(datastruct.ephys.data,2);

	if email_noisecut>0 & nchannels>0

		disp('Checking noise level');

		[bnoise,anoise]=iirpeak(60/(datastruct.ephys.fs/2),5/(datastruct.ephys.fs/2));
		noiseflag=zeros(1,nchannels);

		for j=1:nchannels

			linenoise=filtfilt(bnoise,anoise,datastruct.ephys.data(:,j));
			noiselevel=abs(hilbert(linenoise));

			noisethresh=noiselevel>=email_noisecut;
			noiselen=sum(noisethresh)/datastruct.ephys.fs;
			noiseflag(j)=noiselen>email_noiselen;

		end

		disp('Noise level flags:  ');

		for j=1:nchannels
			fprintf(1,'%i',noiseflag(j));
		end

		fprintf(1,'\n');

		% if all channels have high noise levels, alert the user

		% TODO:  setting for checking across multiple files (could use simple counter)

		if all(noiseflag) & EMAIL_FLAG==0 & email_monitor>0
			gmail_send(['Found excessive noise levels on all channels, make sure headstage is connected!']);
			EMAIL_FLAG=1; % don't send another e-mail!
		end

	end

	% if we're successful reading, then move the file to a processed directory

	[path,name,ext]=fileparts(proc_files{i});

	% if user passes multiple birds, they are split by bird_delimiter, parsing is done
	% independently for each bird

	bird_split=regexp(name,bird_delimiter,'split');

	tokens=regexp(bird_split{end},delimiter,'split');

	% get the date tokens from the last bird, append to all others

	%datetokens=find(parse_string=='d');
	datetokens=[length(tokens)-1 length(tokens)];
	datestring='';

	for j=1:length(datetokens)
		datestring=[ datestring delimiter(end) tokens{datetokens(j)} ];
	end

	nbirds=length(bird_split);

	% clear out all extraction variables to be safe

	found_ports=unique(datastruct.ephys.ports); % which ports are currently being used?

	disp(['Found ports:  ' found_ports]);

	for j=1:nbirds

		sleep_flag=0;
		song_bin=[];

		norm_data=[];
		conditioned_data=[];
		ttl_data=[];

		norm_extraction=[];
		audio_extraction=[];
		ephys_extraction=[];
		ttl_extraction=[];
		sonogram_im=[];
		chunk_sonogram_im=[];

		% parse the file using the format string, insert parse options for manual option setting

		if j<nbirds
			bird_split{j}=[bird_split{j} parse_options datestring];
		end

		% auto_parse

		[birdid,recid,mic_trace,mic_source,mic_port,ports,ttl_trace,ttl_source,...
			playback_trace,playback_source,file_datenum]=...
			intan_frontend_fileparse(bird_split{j},delimiter,parse_string,date_string);

		if ~isempty(user_birdid)
			birdid=user_birdid;
		end

		if ~isempty(user_recid)
			recid=user_recid;
		end

		disp(['Parameter setting method:  ' parse_method]);
		disp(['Processing bird ' num2str(j) ' of ' num2str(nbirds) ]);
		disp(['File date:  ' datestr(file_datenum)]);
		disp(['Bird ID:  ' birdid]);
		disp(['Rec ID:  ' recid]);
		disp(['Mic ch:  ' num2str(mic_trace)]);
		disp(['Mic source:  ' mic_source]);
		disp(['Mic port:  ' mic_port]);
		disp(['TTL ch:  ' num2str(ttl_trace)]);
		disp(['TTL source:  ' ttl_source]);
		disp(['Playback ch:  ' num2str(playback_trace)]);
		disp(['Playback source:  ' playback_source]);
		disp(['Data ports:  ' ports]);
		disp(['File status:  ' num2str(datastruct.filestatus)]);
		% now create the folder it doesn't exist already

		foldername=fullfile(root_dir,birdid,recid,datestr(file_datenum,folder_format));	

		% create the bird directory

		if ~exist(fullfile(root_dir,birdid),'dir')
			mkdir(fullfile(root_dir,birdid));
		end

		% create the template directory and a little readme

		if ~exist(fullfile(root_dir,birdid,'templates'),'dir')
			mkdir(fullfile(root_dir,birdid,'templates'));
			copyfile(fullfile(script_path,'template_readme.txt'),...
				fullfile(root_dir,birdid,'templates','README.txt'));
		end

		if ~isempty(ports)

			include_ports=[];

			for k=1:length(ports)

				if any(ismember(lower(found_ports(:)),lower(ports(k))))
					include_ports=[include_ports ports(k)];
				end
			end
		else
			include_ports=found_ports;
		end

		include_ports=upper(include_ports);

		disp(['Will extract from ports: ' include_ports]);

		include_ephys=[];
		include_aux=[];
		include_id='';

		for k=1:length(include_ports)

			len=length(find(datastruct.ephys.ports==include_ports(k)));

			include_ephys=[include_ephys find(datastruct.ephys.ports==include_ports(k))];
			include_aux=[include_aux find(datastruct.aux.ports==include_ports(k))];
			include_id=[include_id repmat(include_ports(k),[1 len])];

		end

		fprintf(1,'Raw channel mapping for port: ');

		for k=1:length(include_ephys)
			fprintf(1,'%i(%s) ',include_ephys(k),include_id(k));	
		end

		fprintf(1,'\n');

		% map to a new structure with the appropriate ports

		datastruct.file_datenum=file_datenum;

		birdstruct=datastruct;

		birdstruct.ephys.labels=birdstruct.ephys.labels(include_ephys);
		birdstruct.ephys.ports=birdstruct.ephys.ports(include_ephys);
		birdstruct.ephys.data=birdstruct.ephys.data(:,include_ephys);

		birdstruct.aux.labels=birdstruct.aux.labels(include_aux);
		birdstruct.aux.ports=birdstruct.aux.ports(include_aux);
		birdstruct.aux.data=birdstruct.aux.data(:,include_aux);

		% if file contains sampling rate, overwrite and use file's fs

		if ~exist(foldername,'dir')
			mkdir(foldername);
		end

		% standard song detection

		ismic=~isempty(mic_trace);
		isttl=~isempty(ttl_trace);
		isplayback=~isempty(playback_trace);

		disp(['Flags: mic ' num2str(ismic) ' ttl ' num2str(isttl) ' playback ' num2str(isplayback)]);

		% if we use a ttl trigger, assume the source is digital

		if isplayback
			switch(lower(playback_source(1)))

				case 'c'

					playback_channel=find(playback_trace==birdstruct.adc.labels);

					birdstruct.playback.data=birdstruct.adc.data(:,playback_channel);
					birdstruct.playback.fs=birdstruct.adc.fs;
					birdstruct.playback.t=birdstruct.adc.t;

					birdstruct.adc.data(:,playback_channel)=[];
					birdstruct.adc.labels(playback_channel)=[];

					if isempty(birdstruct.adc.data)
						birdstruct.adc.t=[];
					end


				case 'd'

					playback_channel=find(playback_trace==birdstruct.digin.labels);

					birdstruct.playback.data=birdstruct.digin.data(:,playback_channel);
					birdstruct.playback.fs=birdstruct.digin.fs;
					birdstruct.playback.t=birdstruct.digin.t;

					birdstruct.digin.data(:,playback_channel)=[];
					birdstruct.digin.labels(playback_channel)=[];

					if isempty(birdstruct.digin.data)
						birdstruct.digin.t=[];
					end
	
			end

			if ~isempty(filtering)
				[b,a]=butter(5,[filtering/(birdstruct.playback.fs/2)],'high'); % don't need a sharp cutoff, butterworth should be fine
			else
				b=[];
				a=[];
			end


			if ~isempty(filtering)
				birdstruct.playback.norm_data=filtfilt(b,a,birdstruct.playback.data);
			else
				birdstruct.playback.norm_data=detrend(birdstruct.playback.data);
			end

			% don't amplitude normalize playback data, volume is used for detection!!!!

			%birdstruct.playback.norm_data=birdstruct.playback.norm_data./max(abs(birdstruct.playback.norm_data));


		else
			birdstruct.playback.data=[];
		end

		if isttl

			switch lower(ttl_source(1))

				case 'c'

					ttl_channel=find(ttl_trace==birdstruct.adc.labels);

					birdstruct.ttl.data=birdstruct.adc.data(:,ttl_channel);
					birdstruct.ttl.fs=birdstruct.adc.fs;
					birdstruct.ttl.t=birdstruct.adc.t;

					birdstruct.adc.data(:,ttl_channel)=[];
					birdstruct.adc.labels(ttl_channel)=[];

					if isempty(birdstruct.adc.data)
						birdstruct.adc.t=[];
					end


				case 'd'

					ttl_channel=find(ttl_trace==birdstruct.digin.labels);

					birdstruct.ttl.data=birdstruct.digin.data(:,ttl_channel);
					birdstruct.ttl.fs=birdstruct.digin.fs;
					birdstruct.ttl.t=birdstruct.digin.t;

					birdstruct.digin.data(:,ttl_channel)=[];
					birdstruct.digin.labels(ttl_channel)=[];

					if isempty(birdstruct.digin.data)
						birdstruct.digin.t=[];
					end


			end

		else
			birdstruct.ttl.data=[];
		end

		if ismic		

			% (m)ain channels (i.e. electrode channel), (a)ux or a(d)c?

			switch lower(mic_source(1))

				case 'm'

					mic_channel=find(birdstruct.ephys.labels==mic_trace&birdstruct.ephys.ports==mic_port);

					% take out the mic channel from the ephys labels

					birdstruct.audio.data=birdstruct.ephys.data(:,mic_channel);
					birdstruct.audio.fs=birdstruct.ephys.fs;
					birdstruct.audio.t=birdstruct.ephys.t;

					birdstruct.ephys.data(:,mic_channels)=[];
					birdstruct.ephys.labels(mic_channel)=[];

					if isempty(birdstruct.ephys.data)
						birdstruct.ephys.t=[];
					end

				case 'a'

					mic_channel=find(birdstruct.aux.labels==mic_trace&birdstruct.aux.ports==mic_port);

					birdstruct.audio.data=birdstruct.aux.data(:,mic_channel);
					birdstruct.audio.fs=birdstruct.aux.fs;
					birdstruct.audio.t=birdstruct.aux.t;

					birdstruct.aux.data(:,mic_channel)=[];
					birdstruct.aux.labels(mic_channel)=[];

					if isempty(birdstruct.aux.data)
						birdstruct.aux.t=[];
					end

				case 'c'

					mic_channel=find(birdstruct.adc.labels==mic_trace);

					birdstruct.audio.data=birdstruct.adc.data(:,mic_channel);
					birdstruct.audio.fs=birdstruct.adc.fs;
					birdstruct.audio.t=birdstruct.adc.t;

					birdstruct.adc.data(:,mic_channel)=[];
					birdstruct.adc.labels(mic_channel)=[];

					if isempty(birdstruct.adc.data)
						birdstruct.adc.t=[];
					end

			end

			% set up high-pass for mic data if indicated by the user

			if ~isempty(filtering)
				[b,a]=butter(5,[filtering/(birdstruct.audio.fs/2)],'high'); % don't need a sharp cutoff, butterworth should be fine
			else
				b=[];
				a=[];
			end

			if ~isempty(filtering)
				birdstruct.audio.norm_data=filtfilt(b,a,birdstruct.audio.data);
			else
				birdstruct.audio.norm_data=detrend(birdstruct.audio.data);
			end

			birdstruct.audio.norm_data=birdstruct.audio.norm_data./max(abs(birdstruct.audio.norm_data));
		else
			birdstruct.audio.data=[];
			birdstruct.audio.norm_data=[];

		end


		if ~isempty(file_datenum) & length(sleep_window)==2

			% convert the sleep window times to datenum

			[~,~,~,hour]=datevec(file_datenum);

			% compare hour, are we in the window?

			if hour>=sleep_window(1) | hour<=sleep_window(2)

				disp(['Processing sleep data for file ' proc_files{i}]);

				intan_frontend_sleepdata(birdstruct,bird_split{j},sleep_window,sleep_segment,sleep_fileinterval,sleep_pre,...
					fullfile(root_dir,birdid,recid),folder_format,delimiter,parse_string);	

				sleep_flag=1;

				% TODO: skip song detection?

			end
		end

		intan_frontend_extract_mkdirs(foldername,image_pre,wav_pre,data_pre,isttl,isplayback);

		% set up file directories

		image_dir=fullfile(foldername,image_pre);
		wav_dir=fullfile(foldername,wav_pre);
		data_dir=fullfile(foldername,data_pre);

		image_dir_ttl=fullfile(foldername,[image_pre '_ttl']);
		wav_dir_ttl=fullfile(foldername,[wav_pre '_ttl']);
		data_dir_ttl=fullfile(foldername,[data_pre '_ttl']);

		image_dir_pback=fullfile(foldername,[image_pre '_pback']);
		wav_dir_pback=fullfile(foldername,[wav_pre '_pback']);
		data_dir_pback=fullfile(foldername,[data_pre '_pback']);

		if ~ismic & ~isttl & ~sleep_flag & ~isplayback

			save(fullfile(data_dir,['songdet1_' bird_split{j} '.mat']),'-struct','birdstruct','-v7.3');
			clearvars birdstruct;

			continue;

		end

		% if we have a TTL trace, extract using the TTL

		dirstructttl=struct('image',image_dir_ttl,'wav',wav_dir_ttl,'data',data_dir_ttl);
		dirstructpback=struct('image',image_dir_pback,'wav',wav_dir_pback,'data',data_dir_pback);
		dirstruct=struct('image',image_dir,'wav',wav_dir,'data',data_dir);

		% first check TTL, sometimes we want to bail after TTL (ttl_skip)
		% second check playback, sometimes we want to bail after TTL/playback (min. amplitude threshold)
		% finally check for song


		if isttl

			detection=birdstruct.ttl.data(:)>.5;
			ext_pts=intan_frontend_collate_idxs(detection,round(audio_pad*birdstruct.ttl.fs));

			if ~isempty(ext_pts)

				disp('Found ttl..');

				intan_frontend_dataextract(bird_split{j},birdstruct,dirstructttl,...
					ext_pts,disp_minfs,disp_maxfs,colors,'audio',1,'songdet1_','_ttl');

				% if we found TTL pulses and ttl_skip is on, skip song detection and move on to next file

				if ttl_skip
					disp('Skipping song detection...');
					continue;
				end	

			end
		end

		% did we detect playback?

		% run song detection on the playback signal...


		if isplayback & playback_extract
		
			% insert song detection code, change audio to playback?, or pass flag for show 
			% playback data
		
			disp('Entering playback detection...');

			% simply take rms of playback signal
			
			rmswin_smps=round(playback_rmswin*birdstruct.playback.fs);
			rms=sqrt(smooth(birdstruct.playback.norm_data.^2,rmswin_smps));

			detection=rms>playback_thresh;
			ext_pts=intan_frontend_collate_idxs(detection,round(audio_pad*birdstruct.playback.fs));

			if ~isempty(ext_pts)

				disp('Found playback...');

				intan_frontend_dataextract(bird_split{j},birdstruct,dirstructpback,...
					ext_pts,disp_minfs,disp_maxfs,colors,'playback',1,'songdet1_','_pback');
				%intan_frontend_dataextract(bird_split{j},birdstruct,dirstructpback,...
				%	ext_pts,disp_minfs,disp_maxfs,colors,'audio',1,'songdet1_','');

				if playback_skip
					disp('Skipping song detection...');
					continue;
				end
			end

		end

		% did we detect song?

		if ismic

			try
				disp('Entering song detection...');
				[song_bin,~,~,song_t]=song_det(birdstruct.audio.norm_data,birdstruct.audio.fs,minfs,maxfs,window,...
					noverlap,songduration,ratio_thresh,song_thresh,pow_thresh);
			catch err
				disp([err]);
				disp('Song detection failed, continuing...');
				fclose('all');
				continue;
			end

			raw_t=[1:length(birdstruct.audio.norm_data)]./birdstruct.audio.fs;

			% interpolate song detection to original space, collate idxs

			detection=interp1(song_t,double(song_bin),raw_t,'nearest'); 
			ext_pts=intan_frontend_collate_idxs(detection,round(audio_pad*birdstruct.audio.fs));

			if ~isempty(ext_pts)
				disp(['Song detected in file:  ' proc_files{i}]);
				intan_frontend_dataextract(bird_split{j},birdstruct,dirstruct,...
					ext_pts,disp_minfs,disp_maxfs,colors,'audio',1,'songdet1_','');	
			end

		end

		% clear the datastructure for this bird

		clear birdstruct;

	end

	% if there is neither a mic nor a TTL signal, store everything

	clearvars datastruct dirstruct dirstructttl;

	try
		movefile(proc_files{i},proc_dir);
	catch
		disp(['Could not move file ' proc_files{i}]);
		fclose('all');
		continue;
	end

end
