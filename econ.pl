#!/usr/bin/perl -w -CS
use strict;
use utf8;
use Data::Dumper;
use AnyEvent;
use AnyEvent::Socket;
use AnyEvent::Handle;
use v5.16;
use DBI;
#use encoding 'utf8';
#use Encode qw/decode/;
use lib '/var/www/sys/lib/';
use mk::metric;
use mk::flood;
use mk::translator;
use mk::trivia;
use Geo::IP::PurePerl;
use DateTime::Duration::Fuzzy qw(time_ago);
my $gi = Geo::IP::PurePerl->open('/var/www/sys/lib/GeoLiteCity.dat');
my $metric=new mk::metric;
my $translator=new mk::translator;

use constant {
	VERSION => 0.952,		# версия
	DELAY_RAND_MSG=>480,		# период случайного сообщения
	DELAY_MK_GUARD=>3600,		# период broadcast сообщения
	DELAY_SHUTDOWN=>600,		# минимальное время между перезапусками
	FOUL_RATIO=>0.09,		# отношение мат/сообщения
	FOUL_THRESHOLD=>3,		# порог мата
	FOUL_LIMIT=>15,			# предел мата
	FOUL_PAUSE_PROB=>0.8,		# шанс на фриз при мате
	FOUL_MULT=>45,			# множитель, секунд мьюта за мат
	FREQ_MAX=>80,			# максимум накопленных очков частотного анализа
	FREQ_PUNISH=>-160,		# очки ЧА, за которые наказывать
	FREQ_MULT=>30,			# множитель за порядок флуда
	CAPS_MAX=>15,			# максимум накопленных очков капс анализа
	CAPS_PUNISH=>-3,		# очки КА, за которые наказывать
	CACHE_TIME=>600,		# время устаревания кеша игроков
	MK_MAX_LENGHT=>100,		# максимальная длина ответа /mk
	TRANSLIT_RELAX=>0.2,		# предел транслита
	TRANSLIT_MULT=>60,		# Множитель за порядок транслита
	TRANSLIT_THRESHOLD=>4,		# порог транслита
	TRIVIA_MAXMUTE=>20,		# максимальный мьют за неправильный ответ
};

my %delays=(
	'tr'=>		10,	# задержка переводчика
	fortune=>	120,	# задержка фортунки
	geoip=>		20,	# задержка geoip
	alias=>		20,	# псевдонимы
	mail=>		120,	# почта
	mk=>		60,	# /mk
	trivia=>	30,	# trivia
);
#$|=0;

my $pass=404;
my %servers=(
	praeferox=>	{port=>8320},
	electi=>	{port=>8321},
	aperta=>	{port=>8322},
	sapientia=>	{port=>8323},
	insignis=>	{port=>8324},
	expertus=>	{port=>8325},
	fortis=>	{port=>8326}
);
my %sockets;
my %watchers;
my %cache;

$0=~m#(.+)/(.+)#;
require "$1/common.pl";
my $root=$1;
my $data_path="$root/data/econ.dat";
my %plr;
if(-f $data_path and time>CACHE_TIME+ -M $data_path){
	$_=&info_restore($data_path);
	#warn Dumper $_;
	%cache=%{$_};
}
unlink $data_path;
$SIG{TERM}=$SIG{INT}= sub{
	for my $srv(keys %plr){
		for my $id(0..@{$plr{$srv}}){
			&cache_plr($srv,$id) if exists $plr{$srv}[$id];
		}
	}
	&info_dump($data_path,\%cache);
	exit;
};

my @maps=</home/disarmer/.teeworlds/maps/*.map>;
map {s#.*/##;s#\.map$##} @maps;

my %handlers=(
	quit=>sub{say "Goodbye!" and exit},
	diag=>sub{
		my $re=shift;
		for my $srv(keys %plr){
			say "$srv:	", Dumper $plr{$srv} if $srv=~m/$re/;
		}
	},
	cache=>sub{say Dumper \%cache},
	shutdown=>sub{
		for my $srv(keys %servers){
			&srv_shutdown($srv);
		}
	},
);


my $dbh = DBI->connect_cached("dbi:Pg:dbname=disarmer;host=/run/postgresql/;", "disarmer", "devel") or die "DB: $!";
$dbh->{'pg_enable_utf8'}=1;
$dbh->do("SET synchronous_commit TO OFF");
$_=$dbh->prepare("select max(id) from tw_chat");
$_->execute;
my $last_chat_id=$_->fetchrow_array;
my $trivia=new mk::trivia($dbh);

my %sth=(
	rank=>"SELECT rank,summ FROM( select rank() OVER (ORDER BY summ DESC) AS rank,nick,summ from(select nick, sum(score) as summ FROM tw_records GROUP BY nick) as qq) as qw WHERE nick=?",
	#foul=>"select count(1),sum(foul) from tw_chat where player=?",
	random=>"select message,nick from tw_chat join tw_players on tw_players.id=tw_chat.player where tw_chat.id=? AND pm is null and foul=0",
	rand_plr=>"select message,nick from (select message,player from tw_chat where player=? AND pm is null order by id DESC limit 5000) AS FOO JOIN tw_players on tw_players.id=FOO.player order by message ~* ? desc,random() limit 1",
	alias=>"select player from tw_player_stat_view where ip<<? GROUP BY player ORDER BY count(1) DESC limit 10",
	mail_check=>"select sender, text,extract(epoch from sended) from tw_mail where recipient=? and received is NULL ORDER BY sended LIMIT 1;",
	mail_write=>"insert into tw_mail (sender,recipient,text) VALUES (?,?,?)",
	mail_mark=>"update tw_mail SET received=NOW() where sender=? AND recipient=? and received is NULL AND text=?;",
	mail_count=>"select count(1) from tw_mail where recipient=? and received is NULL;",
	map_sim=>"select t1.map,t1.hard,t1.time,t1.tees, sqrt(abs(pow(COALESCE(t1.hard,75),2)-pow(COALESCE(t2.hard,75),2)))+sqrt(abs(pow(COALESCE(t1.time,9999),2)-pow(COALESCE(t2.time,9999),2)))/100 +abs(100*(t1.tees-t2.tees)) as dist from tw_maps t1 join tw_maps t2 on 1=1 where t2.map=? and t1.map!=t2.map order by dist asc limit 20;",
	map_motd=>"select time,hard,tees from tw_maps where map=?",
	map_top=>"select nick,time,score from tw_records where map=? order by time limit ?",
	map_records=>"select count(1) from tw_records where map=?",
	chat_write=>"insert into tw_chat (server,player,message,time) values (?,?,?,to_timestamp(?))",
	nick2id=>'select id from tw_players where nick=?',
	add_plr=>'insert into tw_players (nick) values (?) RETURNING id',
	top_lost=>'select count(1),lost.lost from (select T1.rank>T2.rank as lost from tw_records T1 RIGHT JOIN tw_records_week T2 ON T1.map=T2.map AND T1.nick=T2.nick AND T1.rank!=T2.rank where T1.nick=? and (T2.rank<=5 OR T1.rank<=5)) AS lost group by lost'
);
for(keys %sth){
	$sth{$_}=$dbh->prepare($sth{$_});
}

sub nick2id{
	my $nick=shift;
	$sth{nick2id}->execute($nick);
	my $i=$sth{nick2id}->fetchrow_array;
	return $i if $i;
	$sth{add_plr}->execute($nick);
	return $sth{add_plr}->fetchrow_array;
}

my %replace=(
	qr/%([1-9])%(\ ?)/=>sub{
	$_=mk::flood::phrase($1);
	$_=~s/\W$// unless $2 eq ' ';#,,,=^o_._o^=,,,: disarmer: а можешь сделать чтоб к 1 слову знаки препинания не добавлялись? или если нет пробела после %, например
		return $_;
	},
	qr/%me%/=>sub{
		my %a=@_;
		return $plr{$a{srv}}[$a{id}]{nick};
	},
	qr/%!%/=>sub{
		for(1..2000){
			$_=mk::flood::phrase(1);
			return $_ if $metric->foul($_);
		}
	},
	qr/%#(\d{1,2})%/=>sub{
		my %a=@_;
		return exists $plr{$a{srv}}[$1]?$plr{$a{srv}}[$1]{nick}:'';
	},
	#qr/%%/=>sub{return}
);

my %chat_command=(
	#%_=srv,id,rest	
	test=>sub{
		my %a=%{$_[0]};
		my $str=join ' ',@{$a{rest}};
		&send_command(sprintf('pm %i "<%s>: %3.2f"',$a{id},$str,$metric->freq($str)),$a{srv});
	},
	fortune=>sub{
		my %a=%{$_[0]};
		my $sth;
		if(lc $a{rest}->[0] eq 'my'){
			$sth=$sth{rand_plr};
			local @_=@{$a{rest}};
			shift @_;
			my $re=join ' ',@_;
			my $uid=nick2id($plr{$a{srv}}[$a{id}]{nick});
			$sth->execute($uid,$re);
		}else{
			$sth=$sth{random};
			$sth->execute(int rand $last_chat_id);
		}
		if(@_=$sth->fetchrow_array){
			&send_command(sprintf('say "Fortune: <%s> (%s)"',&escape(@_)),$a{srv});
		}
		return 1;
	},
	alias=>sub{
		my %a=%{$_[0]};
		my $arg=$a{rest}->[0];
		$arg=~y/0-9//cd;
		$arg=$a{id} if $arg eq '';
		my $mask=int $a{rest}->[1]||24;
		my $ip=$plr{$a{srv}}[$arg]{ip} or return;
		$sth{alias}->execute("$ip/$mask");
		my @alias;
		while($_=$sth{alias}->fetchrow_array){
			push @alias,&escape($_);
		}
		&send_command(sprintf('pm %i "Alias %s: <%s>"',$a{id},&escape($plr{$a{srv}}[$arg]{nick}),join ', ',@alias),$a{srv});
		return 1;
	},
	'tr'=>sub{
		my %a=%{$_[0]};
		local @_=@{$a{rest}};
		my($lang,$str)=(shift @_,join ' ',@_);
		my $resp='Error';
		if($str and length($str)>2){
			if($translator->check_lang($lang)){
				my $res=$translator->translate($lang,$str);
				if(defined $res){
					#&send_command(sprintf('say "<translator %s> %s: %s"',$lang,&escape($plr{$srv}[$id]{nick}),&escape($res)),$srv);
					&send_command(sprintf('fake %i "<translator %s> %s"',$a{id},$lang,&escape($res)),$a{srv});
					printf "translator %s> %s: %s -> %s\n",$lang,$plr{$a{srv}}[$a{id}]{nick},$res,$str;
					return 1;
				}else{
					$resp="Unknown error";
				}
			}else{
				$resp='Wrong language definition!';
			}
		}else{
			$resp=sprintf "mk translator. Usage: /tr lang-lang message. Languages: %s",join ',', $translator->languages;
		}
		&send_command(sprintf('pm %i "%s"',$a{id},$resp),$a{srv});
		return 0;
	},
	stat=>sub{
		my %a=%{$_[0]};
		#say Dumper \@_;
		my $arg=$a{rest}->[0];
		$arg=~y/0-9//cd;
		$arg=$a{id} if $arg eq '';
		my $resp;
		if(defined $plr{$a{srv}}[$arg]){
			$resp=sprintf('<diag> %s: msgs %i / foul %i / freq %i / caps %i / translit %.2f',&escape($plr{$a{srv}}[$arg]{nick}),$plr{$a{srv}}[$arg]{chat},$plr{$a{srv}}[$arg]{foul},$plr{$a{srv}}[$arg]{freq},$plr{$a{srv}}[$arg]{caps},$plr{$a{srv}}[$arg]{translit});
		}else{
			$resp='Bad id!';
		}
		&send_command(sprintf('pm %i "%s"',$a{id},$resp),$a{srv});
	},
	geoip=>sub{
		my %a=%{$_[0]};
		my $ret=1;
		my $arg=$a{rest}->[0];
		$arg=~y/0-9//cd;
		$arg=$a{id} if $arg eq '';
		my $resp;
		if($arg=~m/^\d+$/ and defined $plr{$a{srv}}[$arg]){
			$resp=&get_ip_str($plr{$a{srv}}[$arg]{ip},$plr{$a{srv}}[$arg]{nick});
			$resp||=sprintf "I don't know where %s from",$plr{$a{srv}}[$arg]{nick};
		}else{
			$resp='Bad id!';
			$ret=0;
		}
		&send_command(sprintf('pm %i "%s"',$a{id},&escape($resp)),$a{srv}) if $resp;
		return $ret;
	},
	mail=>sub{
		my %a=%{$_[0]};
		my $arg=join ' ',@{$a{rest}};
		my $resp;
		my $ret=0;
		my $player=$plr{$a{srv}}[$a{id}]{nick};
		if(!$arg){
			$sth{mail_check}->execute($player);
			if(@_=$sth{mail_check}->fetchrow_array){
				$resp=sprintf "Message from '%s', %s",$_[0],time_ago(DateTime->from_epoch(epoch=>$_[2]));
				&send_command(sprintf('pm %i "%s"',$a{id},&escape($resp)),$a{srv}) if $resp;
				$resp=$_[1];
				$sth{mail_mark}->execute($_[0],$player,$_[1]);
			}else{
				$resp="You have got no new messages";
			}
		}else{
			if($arg=~m/^(["']?)(.+?)(\1)\s+(\w+.*)$/){
				my ($recipient,$msg)=($2,$4);
				$sth{mail_write}->execute($player,$recipient,$msg);
				$resp="Sending...";
				for my $s(keys %plr){
					for my $i(0..@{$plr{$s}}){
						next unless ref $plr{$s}[$i];
						if($plr{$s}[$i]{nick} eq $recipient){
							&send_command(sprintf('pm %i "You got message from %s. Use /mail to read it"',$i,&escape($player)),$a{srv});
							$resp="Delivered!";
							$ret=1;
						}
					}
				}
			}else{
				$resp="Usage: /mail \"recipient nick\" message text";
			}
		}
		&send_command(sprintf('pm %i "%s"',$a{id},&escape($resp)),$a{srv}) if $resp;
		return $ret;
	},
	mk=>sub{
		my %a=%{$_[0]};
		my $arg=join ' ',@{$a{rest}};
		my $player=$plr{$a{srv}}[$a{id}]{nick};
		while(my($k,$v)=each %replace){
			$arg=~s/$k/$v->(%a)/ex && $arg=~s/$k/$v->(%a)/ex;
			#$arg=~s/$k/$v->(%a)=~y#%#&#/gx;
		}
		$arg=substr $arg,0,MK_MAX_LENGHT if length $arg>MK_MAX_LENGHT;
		if($arg=~m/%USERNAME%/i){
			for my $targ(&player_list($a{srv})){
				$_=$plr{$a{srv}}[$targ]{nick};
				my $temp=$arg;
				$temp=~s/%USERNAME%/$_/i;
				&send_command(sprintf('faketo %i %i "%s"',$a{id},$targ,&escape($temp)),$a{srv});
			}
			$sth{chat_write}->execute($a{srv},nick2id($player),$arg,int time);
			return 1;
		}
		&send_command(sprintf('fake %i "%s"',$a{id},&escape($arg)),$a{srv});
		#$sth{chat_write}->execute($a{srv},$player,$arg,int time);
		#print Dumper [$a{srv},$player,$arg,int time];
		return 1;
	},
	trivia=>sub{
		my %a=%{$_[0]};
		my $arg=lc join ' ',@{$a{rest}};
		my $ret;
		if($arg eq 'hint'){
			if($trivia->active){
				$trivia->hint(1+int($trivia->remains/4));
				$ret=sprintf "%s",$trivia->ask({new=>0,len=>134});
			}else{
				$ret=$trivia->ask({new=>1,len=>150});
			}
		}elsif($arg eq 'ask'){
			if($trivia->active and $trivia->remains>2){
				&send_command(sprintf('pm %i "Еще остались подсказки!"',$a{id}),$a{srv});
				return 0;
			}
			$ret=$trivia->ask({new=>1,len=>150});
		}else{
			&send_command(sprintf('pm %i "Invalid argument. Valid arguments are: ask, hint"',$a{id}),$a{srv});
			return 0;
		}
		return 1 unless $ret;
		&send_command(sprintf('say "Trivia: %s"',&escape($ret)),$a{srv});
		return 1;
	},
);

printf "AnyEvent model:	%s\n",$AnyEvent::MODEL;
$watchers{stdin}=AE::io \*STDIN, 0, sub {
	&stdin(scalar <STDIN>);
};
for my $srv(keys %servers){
	&reconnect($srv);
}
$watchers{random_msg}=AE::timer DELAY_RAND_MSG,DELAY_RAND_MSG, sub {
	$sth{random}->execute(int rand $last_chat_id);
	if(@_=$sth{random}->fetchrow_array){
		#utf8::encode($_);
		&send_command(sprintf('say "<%s> (%s)"',&escape(@_)));
	}
};
$watchers{cache_cleaner}=AE::timer CACHE_TIME,CACHE_TIME, sub {
	for(keys %cache){
		delete $cache{$_} if $cache{$_}{cached}+CACHE_TIME<=time;
	}
	&send_command('status');
};
$watchers{mk_guard}=AE::timer 3,DELAY_MK_GUARD, sub {
	my @mk_greetings=(
		"mk guard %g started",
		"mk guard %g here!",
		"I'm mk guard %g and i see you!",
		"mk guard %g is watching you!",
		"mk guard %g is looking for new victim",
		"mk guard %g woke up!"
	);
	my $mk=sprintf $mk_greetings[int rand @mk_greetings],VERSION;
	&send_command(sprintf 'broadcast "%s"',&escape($mk));
};

AE::cv->recv();

#subs
sub reconnect{
	my $srv=shift or die;
	say "Connecting $srv....";
	$sockets{$srv}->destroy if exists $sockets{$srv};
	tcp_connect '127.0.0.1', $servers{$srv}{port}, sub {
		my $sub=sub {
			printf "Error: %s\n", $_[2]||$!;
			$_[0]->destroy if ref $_[0];
			$servers{$srv}{reconnect_watcher}=AE::timer 10,0, sub {
				&reconnect($srv);
			};
		};
		my ($fh) = @_ or $sub->() and return;

		my $handle; # avoid direct assignment so on_eof has it in scope.

		$handle = new AnyEvent::Handle
			fh				=> $fh,
			on_eof			=>$sub,
			on_connect_error=>$sub,
			on_error		=>$sub;
		$sockets{$srv}=$handle;
		
		$handle->push_write (sprintf "%s$/status$/",$pass);

		$handle->push_read (line => "", sub {
			my ($handle, $line) = @_;
			$handle->on_read (sub {
				my $r=$_[0]->rbuf;
				$_[0]->rbuf='';
				utf8::decode($r);
				&process($srv,$r);
			});
		});
	}
}

sub stdin{
	local $_=shift;
	s/^\s*(.*?)\s*$/$1/;
	return unless $_;
	if( s/^#(\w+)\b\s*(.*)$//){#command
		return say $handlers{$1}->($2) if exists $handlers{$1};
		say "Bad command: $1";
	}else{
		return say "Blacklisted command: $_" if $_ ~~qw/shutdown/;
		&send_command($_);
	}
}
sub check_delay{
	my ($srv,$id,$realm,$delay)=@_;
	if(exists $plr{$srv}[$id]{delay}{$realm}){
		my $diff=($plr{$srv}[$id]{delay}{$realm}+$delay)-time;
		if($diff>0){
			return $diff;
		}
	}else{
		#print Dumper \@_;
		#say Dumper $plr{$srv}[$id];
		return -1 unless exists $plr{$srv}[$id];
	}
	$plr{$srv}[$id]{delay}{$realm}=time;
	return 0;
}

sub similar_maps{
	my $map=shift or return;
	open FH,'>','/home/disarmer/.teeworlds/new/maps_similar.cfg' or warn $!;
	$sth{map_sim}->execute($map);
	while(my($m,$h,$t,$ts,$d)=$sth{map_sim}->fetchrow_array){
		$ts="$ts tee".($ts>1?'s':'');
		$t=&sec_to_time($t) if defined $t;
		$h=sprintf("%.4g%% hard",$h) if defined $h;
		my $str=join ', ',$h,$ts,$t,(int $d).' diff';
		$str=~s/, ,/,/g;
		$str=~s/^, //;
		printf FH "add_vote \"Map:  %s (%s)\" \"sv_map %s\"\n",$m,$str,$m;
	}
	close FH;
}
sub random_map{
	open my $F,'>','/home/disarmer/.teeworlds/new/maps_random.cfg';
	printf $F "sv_map %s\n",$maps[int rand @maps];
	close $F;
}

sub process{
	my ($srv,$r)=@_;
	for(split "\n",$r){
		next unless m/[\w\d]/;
		warn $_ and next unless m/\[([\w-]+)\]: (.*)/;
		my ($part,$rest)=($1,$2);

		next if grep {$part eq $_} qw/register/;
		if($part eq 'chat' or $part eq 'teamchat'){
			if($rest=~m/^ClientID=(\d+) authed \((.*)\)/){
			
			}elsif($rest=~s/^\s*\*{3} '(.*)' changed name to '(.*)'//){#*** 'Slash*' changed name to 'Slash*[RUS]'
				&send_command(sprintf('status',&escape($_)),$srv);
			}elsif($rest=~s/^\s*\*{3} '(.*)' called vote to change server option '(.*)'.*//){#*** 'disarmer' called vote to change server option 'easy maps' (No reason given)
				my ($plr,$subj)=($1,$2);
				if($subj eq 'similar maps'){
					return &send_command('sv_map',$srv);
				}elsif($subj eq 'random map'){
					&random_map;
				}
			}elsif($rest=~s/^\s*(\d+):(-2|0)://){
				my $id=$1;
				&chat_msg($srv,$id,$rest);
			}
		}elsif($part eq 'Console'){
			if($rest=~m/^Value: (.*)$/){
				&similar_maps($1);
				$rest="Similar maps: $1";
			}
		}elsif($part eq 'chat-command'){
			if($rest=~m/^(\d+) used \/(\w+)\s*(.*?)\s*$/){
				my($id,$com)=($1,$2);
				#say ":::$id $com\n\n";
				return unless exists $chat_command{$com};
				if(exists $delays{$com}){
					my $delay=&check_delay($srv,$id,$com,$delays{$com});
					say join ', ',$srv,$id,$com,$delays{$com},$delay;
					return &send_command(sprintf('pm %i "Don\'t use %s too often! Wait %i s."',$id,$com,$delay),$srv) if $delay;
				}
				local @_=split /\s+/,$3;
				my $res=$chat_command{$com}->({srv=>$srv,id=>$id,rest=>\@_});
				if(defined $res and $res==0){
					delete $plr{$srv}[$id]{delay}{$com};
				}
			}
		}elsif($part eq 'game'){
			if($rest=~m/^kill killer='.*' victim='.*' weapon=/){
				return;
			}elsif($rest=~m/^team_join player='(\d+)\:(.*)' team=[0-9]/){
				my $id=$1;
				my $plr_name=$2;
				my $uid=nick2id($plr_name);
				my ($greeting,%hash)=&greeting($plr_name,$uid,$id,$srv);
				my $w=AE::timer 5,0, sub {&send_command($greeting,$srv);delete $plr{$srv}[$id]{watcher}};
				$plr{$srv}[$id]={%{$plr{$srv}[$id]},nick=>$plr_name,joined=>time,watcher=>$w,%hash};
				if(exists $plr{$srv}[$id]{ip}){
					my $from=&get_ip_str($plr{$srv}[$id]{ip},$plr{$srv}[$id]{nick});
					&send_command(sprintf('say "%s"',&escape($from)),$srv) if $from;
				}
			}elsif($rest=~m/^leave player='(\d+)\:(.*)'$/){
				my($id,$plr_name)=($1,$2);
				&cache_plr($srv,$id);
				&init_shutdown($srv) unless &player_list($srv);
			}
		}elsif($part eq 'server'){
			if($rest=~m/^player has entered the game. ClientID=(.+) addr=(.*)/ or $rest=~m/^player is ready. ClientID=(.*) addr=(.*)/){
				my ($id,$ip)=(hex $1,$2);
				$ip=~s/:\d+//;
				$plr{$srv}[$id]{ip}=$ip;
			}elsif($rest=~m#^maps/(.*)\.map crc is [\da-f]{8}#){#maps/NUT_hardcore_race2.map crc is 6ff8719b
				&send_command((sprintf 'sv_motd "%s"',&escape(&gen_motd($1))),$srv);
			}
		}elsif($part eq 'Server'){
			if($rest=~m/^id=(\d+) addr=([\d\.\:]+) name='(.*)' score=.*/){
				my ($id,$ip,$plr_name)=($1,$2,$3);
				
				$plr{$srv}[$id]=$cache{$plr_name} if exists $cache{$plr_name} and $^T+10>time; #если только запустились то можно взять данные из кеша				
				$plr{$srv}[$id]{nick}=$plr_name;
				my $uid=nick2id($plr_name);
				$plr{$srv}[$id]{uid}=$uid;
				$plr{$srv}[$id]{delay}={} unless exists $plr{$srv}[$id]{delay};
				$ip=~s/:\d+//;
				$plr{$srv}[$id]{ip}=$ip;
			}
		}
		my ($s,$p)=($srv,$part);
		map {$_=substr $_,0,4} $s,$p;
		printf "[%s] [%s]: %s\n", $s,$p,$rest;
	}
}
sub get_ip_str{
	my ($ip,$plr_name)=@_;
	my @from=$gi->get_city_record($ip);
	return (sprintf "%s is from %s (%s)",$plr_name,$from[4]?$from[4]:'unknown',$from[0]) if $from[0];
}
sub gen_motd{
	my $m=shift;
	my $buf="Map: $m\\n";
	$sth{map_records}->execute($m);
	$buf.=sprintf "Records count: %i\\n",$sth{map_records}->fetchrow_array;
	$sth{map_motd}->execute($m);
	if(@_=$sth{map_motd}->fetchrow_array){
		$buf.=sprintf "Avg time: %s\\n",&sec_to_time($_[0]) if defined $_[0];
		$buf.=sprintf "Complexity: %i %%\\n",$_[1] if defined $_[1];
		$buf.=sprintf "Tees required: %s\\n",$_[2];
	}
        $sth{map_top}->execute($m,1);
        if(@_=$sth{map_top}->fetchrow_array){
                $buf.=sprintf "First place: %s with %s\\n",$_[0],&sec_to_time($_[1]);
                $buf.=sprintf "Max score: %.4g\\n",$_[2];
        }
	$buf.="More info: http://disarmer.ru/tee/\\n";
	return $buf
}

sub init_shutdown{
	my $srv=shift;
	my $ts=$servers{$srv}{last_shutdown}?$servers{$srv}{last_shutdown}:0;
	if(time-$ts>DELAY_SHUTDOWN){
		&send_command("broadcast Server restart after 10 seconds!",$srv);
		$servers{$srv}{watcher}=AE::timer 10,0, sub {
			return if &player_list($srv);
			$servers{$srv}{last_shutdown}=time;
			&send_command('say shutdown!',$srv);
			&srv_shutdown($srv);
		};
	}
}

sub player_list{
	my $srv=shift;
	my @plrs=();
	for my $id(0..@{$plr{$srv}}){
		#push @plrs,$plr{$srv}[$id]{nick} if defined $_ and exists $plr{$srv}[$id]{nick};
		push @plrs,$id if defined $_ and exists $plr{$srv}[$id]{nick};
	}
	return wantarray?@plrs:scalar @plrs;
}

sub chat_msg{
	my ($srv,$id,$msg)=@_;
	my $plr_name=$plr{$srv}[$id]{nick};
	if( $msg=~ s/^\Q$plr_name\E: //){
		$msg=~s/^\s+//g;
		my $p=$plr{$srv}[$id];
		$p->{chat}++;

		if(my $f=$metric->foul($msg)){
			$p->{foul}+=$f;
			
			my $factor=$p->{foul}/FOUL_LIMIT;
			$factor=max($factor,1);
			if($p->{foul}>=FOUL_THRESHOLD and $p->{foul}*$factor/$p->{chat}>FOUL_RATIO){
				&send_command(sprintf('say "%s: muted (invective / мат)"',&escape($plr_name)),$srv);
				my $tm=min($p->{foul}- FOUL_THRESHOLD+1,FOUL_LIMIT)*FOUL_MULT;
				&send_command(sprintf('muteid %i %i',$id,$tm),$srv);
				$plr{$srv}[$id]{delay}{tr}=time+$tm;
				if(rand $f > 1 - FOUL_PAUSE_PROB){
					my $freeze=min(450,20+$p->{foul}**2);
					&send_command(sprintf('force_pause %i %i',$id,$freeze),$srv);
					#&send_command(sprintf('pm %i %s',$id,sprintf(m/[а-я]/i?'Заморожен на %i сек':'Freezed for %i s',$freeze)),$srv);
				}
				return 0;
			}else{
				&send_command(sprintf('pm %i %s',$id,($msg=~m/[а-я]/i?'У нас не матерятся!':'Do not use profanity!')),$srv);
			}
		}
		my $freq=$metric->freq($msg);
		$p->{freq}+=$freq;
		if($freq<0){
			if($p->{freq} < FREQ_PUNISH){
				$p->{freq_mute}++;
				&send_command(sprintf('say "%s: muted (flood / чушь)"',&escape($plr_name)),$srv);
				&send_command(sprintf('muteid %i %i',$id,FREQ_MULT*$p->{freq_mute}),$srv);
				$p->{freq} = FREQ_PUNISH/2;
				$p->{freq_mute}=5 if $p->{freq_mute}>5;
				return 0;
			}
		}
		$p->{freq}=FREQ_MAX if $p->{freq}>FREQ_MAX;
		
		if($p->{translit}>0 and $msg=~m/[а-я]/i){
			$p->{translit}=0;
		}
		my $f=$metric->translit($msg,$gi->get_city_record_as_hash($p->{ip})->{country_code});
		$f-=TRANSLIT_RELAX;
		$p->{translit}+=$f;
		$p->{translit}=0 if $p->{translit}<0;	
		if($f>0){
			$p->{translit}+=$f;
			if($p->{translit}>TRANSLIT_THRESHOLD){
				&send_command(sprintf('say "%s: muted (transliteration / транслит)"',&escape($plr_name)),$srv);
				&send_command(sprintf('muteid %i %i',$id,TRANSLIT_MULT*++$p->{translit_mult}),$srv);
				$p->{translit}=0;
			}
		}
		
		if(length $msg> 4){
			my $caps=0.5-$metric->caps($msg);
			$p->{caps}+=$caps*length $msg;
			if($caps<0){
				if($p->{caps} < CAPS_PUNISH){
					&send_command(sprintf('say "%s: muted (uppercase / капс)"',&escape($plr_name)),$srv);
					&send_command(sprintf('muteid %i %i',$id,30),$srv);
					$p->{caps} = CAPS_PUNISH/2;
				}
			}
			$p->{caps}=CAPS_MAX if $p->{caps}>CAPS_MAX;
		}
		
#		my @debug=qw/disarmer/;
#		if($plr_name ~~ @debug ){
#			$plr{$srv}[$id]='92.47.56.201';
#			#&send_command(sprintf('pm %i "<diag>: %s, %5.2f"',$id,$gi->country_code_by_addr($plr{$srv}[$id]{ip}),$metric->translit($msg,$gi->$gi->get_city_record_as_hash($plr{$srv}[$id]{ip})->{country_code})),$srv);
			#&send_command(sprintf('pm %i "<diag>: foul %i,    freq %3.2f,  sum %i / %i / %5.2f"',$id,$metric->foul($msg),$metric->freq($msg),$plr{$srv}[$id]{foul},$plr{$srv}[$id]{chat},$plr{$srv}[$id]{freq}),$srv);
#		}
		if($msg=~s/^_//){
			unless($trivia->active){
				return &send_command(sprintf('pm %i "Trivia: Игра закончилась. Начните новую: /trivia ask"',$id),$srv);
			}
			my $res=$trivia->try($p->{uid},$msg);
			my $ret=sprintf "%s (%.2f)",$trivia->describe($res,{u=>$plr_name,a=>$msg}),$res;
			if($res==1){
				$ret.=sprintf ". %s победил! (%i подсказок)",$plr_name,$trivia->{data}->{hint};
			}else{
				&send_command(sprintf('muteid %i %i 1',$id,3+int((1-$res)*TRIVIA_MAXMUTE)),$srv);
			}
			&send_command(sprintf('say "Trivia: %s"',&escape($ret)),$srv);
		}
		return 0;
	}else{
		warn "$srv: CHAT ERROR $plr_name --- $_";
	}
}
sub send_command{
	my $c=shift;
	my @servers=@_?@_:keys %sockets;
	my $cu=$c;
	utf8::encode($cu);
	
	#printf "sending to %s: %s$/",join (',',@servers),$c;
	for my $srv(@servers){
		#utf8::upgrade($c);
		$sockets{$srv}->push_write("$cu$/");
	}
}
sub greeting{
	my ($plr,$uid,$id,$srv)=@_;
	my %hash=(
		foul=>0,
		translit=>0,
		chat=>0,
		caps=>0,
		uid=>$uid,
	);
	%hash=%{$cache{$plr}} if exists $cache{$plr}{cached} and $cache{$plr}{cached}+CACHE_TIME>=time;
	
	my $out="Welcome $plr";
	$sth{rand_plr}->execute($uid,'');
	if(@_=$sth{rand_plr}->fetchrow_array){
		#utf8::encode($_[0]);
		$out.=sprintf ' "%s"',$_[0];
	}
	$out.='!';
	$sth{rank}->execute($uid);
	if(@_=$sth{rank}->fetchrow_array){
		$out.=sprintf " You have rank %i with %.2f points",@_;
		$sth{top_lost}->execute($uid);
		my $empty=1;
		while(@_=$sth{top_lost}->fetchrow_array){
			$empty=0;
			$out.=$_[1]?". $_[0] top places lost":". $_[0] new top places";
		}
		$out.=' this week' unless $empty;
	}
#	$sth{foul}->execute($plr);
#	if(@_=$sth{foul}->fetchrow_array){
#		$hash{db_foul}=$_[1]/$_[0] if $_[0]>0;
#	}
	$sth{mail_count}->execute($plr);
	if($_=$sth{mail_count}->fetchrow_array){
		&send_command(sprintf('pm %i "You have %i new message(s). Use /mail to read them"',$id,$_),$srv);
	}
	return sprintf('say "%s"',&escape($out)),%hash;
}
sub cache_plr{
	my ($srv,$id)=@_;
	my $nick=$plr{$srv}[$id]{nick} or return;
	delete $plr{$srv}[$id]{watcher} if exists $plr{$srv}[$id]{watcher};
	delete $plr{$srv}[$id]{delay} if exists $plr{$srv}[$id]{delay};
	$plr{$srv}[$id]{cached}=time;
	$cache{$nick}=$plr{$srv}[$id];
}
sub escape{
	local @_=@_;
	map { s/\\/\\\\/g;s/"/\\"/g} @_;
	return @_;
}
sub max{
	my $max=shift;
	map {$max=$_ if $_>$max} @_;
	return $max;
}
sub min{
	my $min=shift;
	map {$min=$_ if $_<$min} @_;
	return $min;
}
sub srv_shutdown{
	my $srv=shift;
	send_command('shutdown',$srv);
	$sockets{$srv}->destroy;
	$servers{$srv}{reconnect_watcher}=AE::timer 10,0, sub {
		&reconnect($srv);
	};
}

