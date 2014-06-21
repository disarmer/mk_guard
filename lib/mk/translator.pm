package mk::translator;
use strict;
use warnings;
use utf8;
use Data::Dumper;
use JSON::XS;
use LWP::UserAgent;
use URI::Escape;
#perl -e 'require "/var/www/sys/lib/mk/translator.pm";my $t=new mk::translator;warn $t->translate('en-ru','test');'
sub new{
	my ($class,%params)=@_;
	my $ua = LWP::UserAgent->new;
	$ua->agent("mk translator/0.1");
	my $self={
		languages=>{ru=>1,en=>1,de=>1,'tr'=>1,uk=>1,fr=>1,es=>1,it=>1,pl=>1,bg=>1,cs=>1,ro=>1,sr=>1},
		cache=>{},
		ua=>$ua,
		%params
	};
	return bless $self, $class;
}

sub check_lang{
	my($self,$l)=@_;
	return 1 if exists $self->{cache}->{$l};
	local $_=$l;
	$_=lc $_;
	return 0 unless m/^(\w{2})-(\w{2})$/;
	return 0 if $1 eq $2;
	map {return 0 unless exists $self->{languages}->{$_}} $1,$2;
	$self->{cache}->{$l}=1;
	return 1;
}
sub languages{
	my $self=shift;
	my @_=keys %{$self->{languages}};
	return @_;
}
sub translate{
	my ($self,$lang,$str)=@_;
	$str=~s/^\s*(.*)\s*$/$1/;
	return undef if length $str<3;
	my $params=sprintf 'key=trnsl.1.1.20130428T193754Z.cdd906739018.3b26a38b17224d8e07082666c5&lang=%s&text=%s',$lang,&url_encode($str);
	my $req = HTTP::Request->new(GET => "https://translate.yandex.net/api/v1.5/tr.json/translate?$params");
	my $res = $self->{ua}->request($req);
	#print Dumper $res;
	if($res->is_success){
		my $json= decode_json $res->content;
		return $json->{text}->[0];
		#return $res->content;
	}else{
		#print $res->status_line,"\n";
		#print Dumper $res;
		return undef;
	}
}
sub url_encode{
	local @_=@_;
	map{ $_=uri_escape_utf8($_)} @_;
	return wantarray?@_:join("\n",@_);
}


1;
