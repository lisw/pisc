local sformat, assert = string.format, assert;
local gettime = require("time").time;

local PACKET_HEAD = '\x7E';
local PACKET_TAIL = '\x7E';
local PACKET_TIME = 0.005;  -- max interval between packet chars in milliseconds

local function checksum(str)
    local sum = 0;
    for i=1, #str do
        sum = sum + str:byte(i);
    end;
    return (0x55 - sum) % 256;
end;

local function hexstring(str)
    local hex="";
    local len = type(str)=="string" and #str or 0;
    len = len > 64 and 64 or len;
    for i=1,#str do
        hex = sformat("%s%02x ", hex, str:byte(i));
    end;
    return hex;
end;

-- build a packet
-- input params:
--   destNet: number(0-255), destination network id
--   destDev: number(0-255), destination device id
--   srcNet: number(0-255), source network id
--   srcDev: number(0-255), source device id
--   cmd: number(0-255), packet command type
--   data: string, packet data
-- return params:
--   the packet string, include packet head & tail
local function pktbuild(destNet, destDev, srcNet, srcDev, cmd, data)
    destNet = tonumber(destNet) or 0;
    destDev = tonumber(destDev) or 0;
    srcNet = tonumber(srcNet) or 0;
    srcDev = tonumber(srcDev) or 0;
    cmd  = tonumber(cmd) or 0;
    data = data or "";
    local pkt = string.char(destNet, destDev, srcNet, srcDev, cmd, #data) .. data;
    pkt = pkt .. string.char(checksum(pkt));
    pkt = pkt:gsub("([\x7E\x7F])", function(c) return string.char(0x7F, 2+c:byte()) end);
    return PACKET_HEAD .. pkt .. PACKET_TAIL;
end;

-- parse a packet
-- input params:
--   pkt: the packet string, include packet head & tail
-- return params:
--   nil, error_string: when packet is invalid
--   destNet, destDev, srcNet, srcDev, cmd, data: when packet is valid
--   @see pktbuild input params
local function pktparse(pkt)
    if type(pkt) ~= "string" or #pkt < 9 then
        return nil, "Invalid packet, too short";
    elseif pkt:byte(1) ~= 0x7E or pkt:byte(-1) ~= 0x7E then
        return nil, "Invalid packet tag";
    end;
    pkt = pkt:sub(2, -2):gsub("\x7F([\x80\x81])", function(c) return string.char(c:byte()-2) end);
    local datalen = pkt:byte(6);
    if #pkt ~= datalen + 7 then
        return nil, "Invalid packet length";
    end;
    local sum = checksum(pkt:sub(1, -2));
    if sum ~= pkt:byte(-1) then
        return nil, sformat("Invalid packet sum:%02x", sum);
    end;
    return pkt:byte(1), pkt:byte(2), pkt:byte(3), pkt:byte(4), pkt:byte(5), pkt:sub(7, -2);
end;

-- receive a packet from udev
-- input params:
--   udev: uart device handle, return from uart.new()
--   wait: optional, when true wait until a packet received or timeout, when false return immediately
-- output params:
--   the packet string when whole packet got, including packet head & tail
--   nil: when no whole packet got
--   nil, error_string: when timeout
local function pktrecv(udev, wait)
    assert(type(udev)=="table", "Invalid first parameter");
    local pkt;
    local buf = udev.pktbuf or "";
    local start = udev.timestart or gettime();
    while true do
        local str = udev:get();
        local now = gettime();
        if str then
            buf = buf .. str;
            start = now;            -- adjust receive time when data arrive
        elseif now > start + PACKET_TIME then -- time gap
            udev.pktbuf = nil;
            udev.timestart = nil;
            return nil, "Receive timeout: " .. buf;
        end;
        local starts,ends = buf:find(PACKET_HEAD, 1, true);
        if starts then
            local _,ends = buf:find(PACKET_TAIL, ends+1, true);
            if ends then
                udev.pktbuf = buf:sub(ends+1);
                udev.timestart = nil;
                return buf:sub(starts, ends);
            end;
        end;

        if wait then
            sleep(0.001);
        else
            break;
        end;
    end;
    udev.pktbuf = buf;
    udev.timestart = start;
end;

local function pktsend(udev, pkt)
    assert(type(udev)=="table", "Invalid first parameter");
    udev:put(pkt);
    udev.timestart = gettime() + 10*#pkt/(udev.baudrate or 9600);
end;

local function pktdump(pkt)
    print(hexstring(pkt));
    local destNet, destDev, srcNet, srcDev, cmd, data = pktparse(pkt);
    if not destNet then
        print(destDev);
    else
        print(destNet, destDev, srcNet, srcDev, cmd);
        print(hexstring(data));
    end;
end;

return {
    build = pktbuild;
    parse = pktparse;

    send = pktsend;
    recv = pktrecv;
    dump = pktdump;

    hexstring  = hexstring;
    checksum  = checksum;
}
