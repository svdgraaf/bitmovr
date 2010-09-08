Name:	    bitmovr
Version:    0.0.1
Summary:    SD-bitmovr, an alternative cproxy
Release:    4
Group:	    System
URL:	    http://www.sanomadigital.nl
Vendor:	    sanomadigital
License:    Unknown
BuildRoot:  %{_tmppath}/%{name}-%{version}-root
Requires:   sd-lua, sd-luasocket, sd-luamd5, sd-luamemcached, memcached

%description
Sanoma Digital 

%build
rm -rf %{buildroot}
svn --force export http://svn.ilsemedia.nl/mediatool/trunk/edge/bitmovr/

%install
rm -rf %{buildroot}
%{__install} -D -m 0755 bitmovr/bitmovr.conf %{buildroot}/etc/bitmovr/bitmovr.conf
%{__install} -D -m 0755 bitmovr/bitmovr.lua %{buildroot}/usr/local/bitmovr/bitmovr.lua
%{__install} -D -m 0755 bitmovr/bitmovr_start.sh %{buildroot}/usr/local/bitmovr/bitmovr_start.sh
%{__install} -D -m 0755 bitmovr/bitmovr.initrc %{buildroot}/etc/rc.d/init.d/bitmovr
%{__install} -D -m 0755 bitmovr/bitmovr.crontab %{buildroot}/etc/cron.d/bitmovr
%{__install} -m 0700 -d $RPM_BUILD_ROOT/data/bitmovr/spinner_cache
rm bitmovr/bitmovr.spec



%files 
%defattr(-,root,root)
/usr/local/bitmovr/bitmovr.lua
/usr/local/bitmovr/bitmovr_start.sh
/etc/bitmovr/bitmovr.conf
/etc/rc.d/init.d/bitmovr
/etc/cron.d/bitmovr
/data/bitmovr/spinner_cache


%post
#/usr/bin/luarocks install md5
/sbin/chkconfig bitmovr on



%clean
rm -rf $RPM_BUILD_ROOT

%changelog
* Fri Jul 2 2010 Marco Lebbink <marco.lebbink@sanomadigital.nl> - 0.0.1
- Initial Release

