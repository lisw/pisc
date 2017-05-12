local sformat, assert = string.format, assert;
local packet = require("packet");
local luaunit = require("luaunit");
sleep = require("time").sleep;

function testchecksum()
    luaunit.assertEquals(packet.checksum("\x01\x02\x03\x04\x05"), 0x55-15);
    luaunit.assertEquals(packet.checksum("\x55"), 0);
    luaunit.assertEquals(packet.checksum("\x56"), 0xff);
    luaunit.assertEquals(packet.checksum("\xff\xff\xff"), 0x58);
    luaunit.assertEquals(packet.checksum(string.rep("\x03", 256)), (0x55-3*256)%256);
    luaunit.assertEquals(packet.checksum("\x03\x16\x01\x11\xB1\x06\x01\x02\x03\x04\x05\x06"), 0x5E);
end;

function testbuild()
    luaunit.assertEquals(packet.build(0, 1, 2, 3, 4), "\x7E\x00\x01\x02\x03\x04\x00\x4B\x7E");
    luaunit.assertEquals(packet.build(0, 0x10, 0, 0, 0xc, "\x00"), "\x7E\x00\x10\x00\x00\x0C\x01\x00\x38\x7E");
    luaunit.assertEquals(packet.build(0, 0x10, 0, 0, 0xc, "\x7E\x7F"), "\x7E\x00\x10\x00\x00\x0C\x02\x7F\x80\x7F\x81\x3A\x7E");
end;

function testparse()
    luaunit.assertEquals({packet.parse("\x7E\x00\x01\x02\x03\x04\x00\x4B\x7E")}, {0,1,2,3,4,""});
    luaunit.assertEquals({packet.parse("\x7E\x00\x10\x00\x00\x0C\x01\x00\x38\x7E")}, {0,0x10,0,0,0xc,"\x00"});
    luaunit.assertEquals({packet.parse("\x7E\x00\x10\x00\x00\x0C\x02\x7F\x80\x7F\x81\x3A\x7E")}, {0,0x10,0,0,0xc,"\x7E\x7F"});
    luaunit.assertEquals({packet.parse("hello")}, {nil, "Invalid packet, too short"});
    luaunit.assertEquals({packet.parse("hello world")}, {nil, "Invalid packet tag"});
    luaunit.assertEquals({packet.parse("\x7E\x00\x01\x02\x03\x04\x01\x4B\x7E")}, {nil, "Invalid packet length"});
    luaunit.assertEquals({packet.parse("\x7E\x00\x01\x02\x03\x04\x00\x4A\x7E")}, {nil, "Invalid packet sum:4b"});
end;

function testrecv()
    local udev={};
    udev.baud=9600;
    udev.put = function(o, pkt) print("send", packet.hexstring(pkt)); end;
    udev.get = function(...)
        local index=udev.index or -1;
        index = index + 1;
        udev.index = index;
        if index==0 then
            return "helloword\x7E";
        elseif index==1 then
            return "\x00\x10\x00\x00\x0C\x01\x00";
        elseif index==2 then
            return "\x38\x7E";
        elseif index==3 then
            return "\x7E\x00\x01\x02\x03\x04\x00\x4B\x7E";
        elseif index==4 then
            return "abcdef01234567";
        else
            return;
        end;
    end;
    luaunit.assertIsNil(packet.send(udev, "\x7E\x00\x01\x02\x03\x04\x00\x4B\x7E"));
    luaunit.assertEquals(packet.recv(udev), nil); 
    luaunit.assertEquals(packet.recv(udev), nil); 
    luaunit.assertEquals(packet.recv(udev), "\x7E\x00\x10\x00\x00\x0C\x01\x00\x38\x7E"); 
    luaunit.assertEquals(packet.recv(udev), "\x7E\x00\x01\x02\x03\x04\x00\x4B\x7E"); 
    luaunit.assertEquals(packet.recv(udev), nil); 
    sleep(0.003);
    luaunit.assertEquals(packet.recv(udev), nil); 
    sleep(0.3);
    luaunit.assertEquals({packet.recv(udev)}, {nil, "Receive timeout: abcdef01234567"}); 

    udev.index = -1;
    luaunit.assertEquals(packet.recv(udev, true), "\x7E\x00\x10\x00\x00\x0C\x01\x00\x38\x7E"); 
    luaunit.assertEquals(packet.recv(udev, true), "\x7E\x00\x01\x02\x03\x04\x00\x4B\x7E"); 
    luaunit.assertEquals({packet.recv(udev, true)}, {nil, "Receive timeout: abcdef01234567"}); 
end;

os.exit(luaunit.run());
