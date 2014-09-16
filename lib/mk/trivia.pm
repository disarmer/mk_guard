package mk::trivia;
use strict;
use warnings;
use utf8;
use Data::Dumper;
use String::Similarity;

sub new{
	my ($class,$dbh)=@_;
	my $sth=$dbh->prepare("select count(1) from trivia;");
	$sth->execute;
	my $count=$sth->fetchrow_array;
	my $self={
		dbh=>$dbh,
		subst=>'.',
		sth=>{
			read	=>"select id,question,answer from trivia where id=?",
			write	=>"insert into trivia_hist (question,player,asked,answered,similarity,hint,text) VALUES (?,?,to_timestamp(?),to_timestamp(?),?,?,?)",
		},
		data=>{active=>0},
		count=>$count,
	};
	map {$_=$dbh->prepare($_)} values $self->{sth};
	return bless $self, $class;
}
sub ask{
	my ($self,$arg)=@_;
	my $len=exists $arg->{len}?int $arg->{len}:300;
	if(exists $arg->{new} and $arg->{new}){
		$self->{sth}->{read}->execute(1+int rand $self->{count});
		$self->{data}=$self->{sth}->{read}->fetchrow_hashref();
		$self->{data}->{asked}=time;
		$self->{data}->{hint}=0;
		$self->{data}->{active}=1;
		$self->{data}->{answer}=lc $self->{data}->{answer};
		$self->{data}->{answer}=~y/etyopahkxcbm/етуоранкхсвм/;
		for(1..length $self->{data}->{answer}){
			substr($self->{data}->{question},$_-1,1)=~y/еЕоОаАТуРрНКХхСсВМ/eEoOaATyPpHKXxCcBM/ if rand>0.5;
		}
		my ($secret)=split ',',$self->{data}->{answer},2;
		$self->{data}->{word}=$self->{subst} x length $secret;
		
		return sprintf "%s (%i букв)",ucfirst substr($self->{data}->{question},0,$len-10),length $secret;
	}
	return sprintf "%s (%s)",ucfirst substr($self->{data}->{question},0,$len-3-length $self->{data}->{word}),$self->{data}->{word};
}
sub active{
	my ($self)=@_;
	return $self->{data}->{active};
}
sub try{
	my ($self,$plr,$answer)=@_;
	my $similarity=0;
	for my $secret(split ',',$self->{data}->{answer}){
		my $sim=similarity(lc $secret,lc $answer);
		$similarity=$sim if $sim>$similarity;
	}
	$self->{sth}->{write}->execute($self->{data}->{id},$plr,$self->{data}->{asked},int time,$similarity,$self->{data}->{hint},$answer);
	if($similarity==1 and $self->{data}->{active}){$self->{data}->{active}=0}
	return $similarity;
}
my $gender={
	какой=>{f=>'какая',n=>'какое',p=>'какие'},
	он=>{f=>'она',n=>'оно',p=>'они'},
	самый=>{f=>'самая',n=>'самое',p=>'самые'},
};
sub mkgender{
	my ($w,$g)=@_;
	$w=lc $w;
	return exists $gender->{$w}->{$g}?$gender->{$w}->{$g}:$w;
}
sub describe{
	my ($self,$s,$h)=@_;
	my $g=$h->{a}=~m/[о]$/i?'n':m/[и]$/i?'p':$h->{a}=~m/[ая]$/i?'f':'m';

	my %h=(
		0.95=>['Точно','Стопудово', 'Верно, %u','Ага, %a','%u - умняшка','%u всех надрал','Самый умный пятиклассник','По-любому, %a','он самый, %u'],
		0.85=>['Почти угадал, %u','Ну-ну-ну, %u','Практически верно','Еще чуть','Поднатужься, %u'],
		0.65=>['Близко, но не %a','Неа','Нет, не %a','Ну нет же','Подумай, %u','А вот и нет!'],
		0.25=>['Не угадал, %u','Мимо','Мазила','какой еще %a?','Чем ты думал, %u?'],
		0.00=>['Совсем не то','Холодно!','Проснись, %u!','Сам ты %a','%u - %a','%u - пупица','Нет и еще раз нет, %u','Ну какой еще %a?','Ахаха, нет, не %a','%u, держи мьют'],
	);
	#%h=(0.5=>['он самый'],0=>['не он']);
	for(sort {$b<=>$a} keys %h){
		if($s>=$_){
			my @a=@{$h{$_}};
			$_=$a[int rand @a];s/%(\w)/$h->{$1}/g;
			for my $w(split /[\b\s]+/,$_){
				s/\Q$w\E/mkgender($w,$g)/eg if exists $gender->{$w};
			}
			return lcfirst $_
		}
	}
}
sub hint{
	my($self,$num)=@_;
	$num||=1;
	my ($secret)=split ',',$self->{data}->{answer},2;
	return $self->{data}->{word} if $self->{data}->{hint}>=length($secret)-1;
	my $guess=0;
	for(1..20){
		return $self->{data}->{word} if $guess==$num or $self->remains<2;
		my $i=int rand length $secret;
		next unless substr($self->{data}->{word},$i,1) eq $self->{subst};
		substr $self->{data}->{word},$i,1,substr($secret,$i,1);
		$self->{data}->{hint}++;
		$guess++;
	}
	return $self->{data}->{word};
}
sub remains{
	my $self=shift;
	return length($self->{data}->{word})-$self->{data}->{hint};
}
1;
