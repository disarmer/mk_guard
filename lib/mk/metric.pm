package mk::metric;
use strict;
use warnings;
use utf8;
use Data::Dumper;

sub new{
	my ($class,%params)=@_;
	my $self={
		ngramms=>{},
		translit=>{},
		foul_re=>[],
		ngramm_len=>0,
		%params
	};
	open FH,'<:utf8',"/home/disarmer/.teeworlds/proj/data/foul_list" or die $!;
	while(<FH>){
		chomp;
		next if $_ eq '';
		push $self->{foul_re},qr/\b$_\b/i; #TODO /oi
	}
	close FH;
	open FH,'<:utf8','/home/disarmer/.teeworlds/proj/data/ngramms.dat' or die $!;
	while(<FH>){
		chomp;@_=split /\s+/,$_,2;
		$self->{ngramms}->{$_[0]}=$_[1];
		$self->{ngramm_len}=length $_[0] unless $self->{ngramm_len};
	}
	close FH;
	open FH,'<:utf8','/home/disarmer/.teeworlds/proj/data/translit.dat' or die $!;
	while(<FH>){
		chomp;local @_=split /\s+/,$_,2;
		$self->{translit}->{$_[0]}=$_[1];
	}
	close FH;
	my $total;
	map {$total+=$_} values %{$self->{ngramms}};
	$self->{ngramm_avg}=$total/scalar keys %{$self->{ngramms}};

	return bless $self, $class;
}
sub foul{
	my($self,$w)=@_;
	my $f=0;
	$w=~s/(.)\1+/$1/g;
	map {$f+=$w=~s/$_/***/g} @{$self->{foul_re}};
	return $f;
}
sub freq{
	my($self,$w)=@_;
	$w=lc $w;
	$w=~y/ё/е/;
	$w=~y/a-zа-я//dc;
	#return -100 if length $w<NGRAMM_LENGTH;
	my $prob=0;
	#warn Dumper $w;
	for my $i(0..(length($w) - $self->{ngramm_len})){
		my $tr=substr $w,$i,$self->{ngramm_len};
		my $count=$self->{ngramms}->{$tr}||0.1;
		#print "$tr,    $count, ",log $count/$self->{ngramm_avg},"\n";
		$prob+=log $count/$self->{ngramm_avg};
	}
	#printf "%-20s: %.3f\n",$str,$prob;
	return $prob;
}
sub caps{
	my($self,$w)=@_;
	my $res=()=$w=~m/\p{Lu}/g;
	return $res/length $w;
}
sub translit{
	my($self,$m,$c)=@_;
	return 0 if $m=~m/[а-я]/i;
	$c=(grep {$c eq $_} qw/RU BY UA KZ/)?1:0.2;
	my $s=0;
	map {$s+=$self->{translit}->{$_} if $m=~m/\b$_\b/ig;print $_,$/ if $m=~m/\b$_\b/ig} keys %{$self->{translit}};
	return $s*$c;
}

1;
