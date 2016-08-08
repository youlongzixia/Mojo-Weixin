package Mojo::Weixin::Client;
use Mojo::Weixin::Client::Remote::_login;
use Mojo::Weixin::Client::Remote::_logout;
use Mojo::Weixin::Client::Remote::_get_qrcode_uuid;
use Mojo::Weixin::Client::Remote::_get_qrcode_image;
use Mojo::Weixin::Client::Remote::_is_need_login;
use Mojo::Weixin::Client::Remote::_synccheck;
use Mojo::Weixin::Client::Remote::_sync;
use Mojo::Weixin::Message::Handle;
use Mojo::IOLoop;
use Mojo::IOLoop::Delay;

use base qw(Mojo::Weixin::Request);

sub login{
    my $self = shift;
    return if $self->login_state eq 'success';
    if($self->is_first_login == -1){
        $self->is_first_login(1);
    }
    elsif($self->is_first_login == 1){
        $self->is_first_login(0);
    }

    if($self->is_first_login){
        $self->load_cookie();
    }

    my $ret = $self->_login();
    if($self->login_state eq "success"){
        $self->model_init();
        $self->emit("login"=>($ret==2?1:0));
    }
    else{
        $self->error("登录失败");
        $self->stop();
    }
}
sub relogin{
    my $self = shift;
    my $retcode = shift;
    $self->info("正在重新登录...\n");
    $self->logout($retcode);
    $self->login_state("relogin");
    $self->ua->cookie_jar->empty;

    $self->sync_key(+{});
    $self->pass_ticket('');
    $self->skey('');
    $self->wxsid('');
    $self->wxuin('');
    $self->deviceid($self->gen_deviceid());

    $self->user(+{});
    $self->friend([]);
    $self->group([]);
    $self->data(+{});

    $self->login();
}
sub logout{
    my $self = shift;
    my $retcode = shift;
    $self->_logout($retcode);
}
sub steps {
    my $self = shift;
    Mojo::IOLoop::Delay->new(ioloop=>$self->ioloop)->steps(@_)->catch(sub {
        my ($delay, $err) = @_;
        $self->error("steps error: $err");
    })->wait;
    $self;
}
sub ready {
    my $self = shift;
    #加载插件
    my $plugins = $self->plugins;
    for(
        sort {$plugins->{$b}{priority} <=> $plugins->{$a}{priority} }
        grep {defined $plugins->{$_}{auto_call} and $plugins->{$_}{auto_call} == 1} keys %{$plugins}
    ){
        $self->call($_);
    }
    $self->emit("after_load_plugin");
    $self->login() if $self->login_state ne 'success';
    #接收消息
    $self->on(synccheck_over=>sub{ 
        my $self = shift;
        my($retcode,$selector) = @_;
        $self->_parse_synccheck_data($retcode,$selector);
        $self->timer($self->synccheck_interval,sub{$self->_synccheck()});
    });
    $self->on(sync_over=>sub{
        my $self = shift;
        my $json = shift;
        $self->_parse_sync_data($json);
    });
    $self->info("开始接收消息...\n");
    $self->_synccheck();
    $self->is_ready(1);
    $self->emit("ready");
}
sub run{
    my $self = shift;
    $self->ready() if not $self->is_ready;
    $self->emit("run");
    $self->ioloop->start unless $self->ioloop->is_running;
}

sub multi_run{
    Mojo::IOLoop->singleton->start unless Mojo::IOLoop->singleton->is_running;
}

sub clean_qrcode{
    my $self = shift;
    return if not defined $self->qrcode_path;
    return if not -f $self->qrcode_path;
    $self->info("清除残留的历史二维码图片");
    unlink $self->qrcode_path or $self->warn("删除二维码图片[ " . $self->qrcode_path . " ]失败: $!");
}

sub timer {
    my $self = shift;
    return $self->ioloop->timer(@_);
}
sub interval{
    my $self = shift;
    return $self->ioloop->recurring(@_);
}

sub exit{
    my $self = shift;
    my $code = shift;
    $self->info("客户端已退出");
    exit(defined $code?$code+0:0);
}
sub stop{
    my $self = shift;
    $self->is_stop(1);
    $self->info("客户端停止运行");
    CORE::exit();
}

sub spawn {
    my $self = shift;
    my %opt = @_;
    require Mojo::Weixin::Run;
    my $is_blocking = delete $opt{is_blocking};
    my $run = Mojo::Weixin::Run->new(ioloop=>($is_blocking?Mojo::IOLoop->new:$self->ioloop),log=>$self->log);
    $run->max_forks(delete $opt{max_forks}) if defined $opt{max_forks};
    $run->spawn(%opt);
    $run->start if $is_blocking;
    $run;
}

sub mail{
    my $self  = shift;
    my $callback ;
    my $is_blocking = 1;
    if(ref $_[-1] eq "CODE"){
        $callback = pop;
        $is_blocking = 0;
    }
    my %opt = @_;
    #smtp
    #port
    #tls
    #tls_ca
    #tls_cert
    #tls_key
    #user
    #pass
    #from
    #to
    #cc
    #subject
    #charset
    #html
    #text
    #data MIME::Lite产生的发送数据
    eval{ require Mojo::SMTP::Client; } ;
    if($@){
        $self->error("发送邮件，请先安装模块 Mojo::SMTP::Client");
        return;
    }
    my @new = (
        address => $opt{smtp},
        port    => $opt{port} || 25,
        autodie => $is_blocking,
    );
    for(qw(tls tls_ca tls_cert tls_key)){
        push @new, ($_,$opt{$_}) if defined $opt{$_};
    }
    my $smtp = Mojo::SMTP::Client->new(@new);
    unless(defined $smtp){
        $self->error("Mojo::SMTP::Client客户端初始化失败");
        return;
    }
    my $data;
    if(defined $opt{data}){$data = $opt{data}}
    else{
        my @data;
        push @data,("From: $opt{from}","To: $opt{to}");
        push @data,"Cc: $opt{cc}" if defined $opt{cc};
        require MIME::Base64;
        my $charset = defined $opt{charset}?$opt{charset}:"UTF-8";
        push @data,"Subject: =?$charset?B?" . MIME::Base64::encode_base64($opt{subject},"") . "?=";
        if(defined $opt{text}){
            push @data,("Content-Type: text/plain; charset=$charset",'',$opt{text});
        }
        elsif(defined $opt{html}){
            push @data,("Content-Type: text/html; charset=$charset",'',$opt{html});
        }
        $data = join "\r\n",@data;
    }
    if(defined $callback){#non-blocking send
        $smtp->send(
            auth    => {login=>$opt{user},password=>$opt{pass}},
            from    => $opt{from},
            to      => $opt{to},
            data    => $data,
            quit    => 1,
            sub{
                my ($smtp, $resp) = @_;
                if($resp->error){
                    $self->error("邮件[ To: $opt{to}|Subject: $opt{subject} ]发送失败: " . $resp->error );
                    $callback->(0,$resp->error) if ref $callback eq "CODE";
                    return;
                }
                else{
                    $self->debug("邮件[ To: $opt{to}|Subject: $opt{subject} ]发送成功");
                    $callback->(1) if ref $callback eq "CODE";
                }
            },
        );
    }
    else{#blocking send
        eval{
            $smtp->send(
                auth    => {login=>$opt{user},password=>$opt{pass}},
                from    => $opt{from},
                to      => $opt{to},
                data    => $data,
                quit    => 1,
            );
        };
        return $@?(0,$@):(1,);
    }

}
sub add_job {
    my $self = shift;
    require Mojo::Weixin::Client::Cron;
    $self->Mojo::Weixin::Client::Cron::add_job(@_);
}

1;
