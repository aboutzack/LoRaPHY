%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
% \file      LoRaPHY.m
%
% \brief     Physical Layer LoRa Modulator/Demodulator/Encoder/Decoder
%
% \copyright MIT License, 2020
%
% \author    jkadbear
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

classdef LoRaPHY < handle
    %LORAPHY LoRa physical layer reverse engineering
    %%% Example %%%
    % sf = 12;
    % bw = 125e3;
    % fs = 1e6;
    % phy = LoRaPHY(sf, bw, fs);
    % phy.has_header = 1; % explicit header mode
    % symbols = [2541,1153,673,2397,1189,3509,41,3089,3237,3917,2729,2765,1417,2833,1389,801,3197,345,961,745,3101,297,1893,469];
    % [data, checksum] = phy.decode(symbols);
    % disp(data); % CODE: 09 90 40 01 02 03 04 05 06 07 08 09 BA 2E
    % disp(checksum);

    properties
        sf                        % spreading factor (7-12)
        bw                        % bandwidth (125kHz 250kHz 500kHz)
        fs                        % sampling frequency
        cr                        % code rate: (1:4/5 2:4/5 3:4/7 4:4/8)
        payload_len               % payload length
        has_header                % explicit header: 1, implicit header: 0
        crc                       % crc = 1 if CRC Check is enabled else 0
        ldr                       % ldr = 1 if Low Data Rate Optimization is enabled else 0
        whitening_seq             % whitening sequence
        crc_generator             % CRC generator with polynomial x^16+x^12+x^5+1
        header_checksum_matrix    % we use a 12 x 5 matrix to calculate header checksum
        preamble_len              % preamble length

        sig                       % input baseband signal
        downchirp                 % ideal chirp with decreasing frequency from B/2 to -B/2
        upchirp                   % ideal chirp with increasing frequency from -B/2 to B/2
        sample_num                % number of sample points per symbol
        bin_num                   % number of bins after FFT (with zero padding)
        zero_padding_ratio        % FFT zero padding ratio
        fft_len                   % FFT size
        preamble_bin              % reference bin in current decoding window, used to eliminate CFO
        cfo                       % carrier crequency offset

        is_debug                  % set `true` for debug information
        hamming_decoding_en       % enable hamming decoding
    end

    methods
        function self = LoRaPHY(sf, bw, fs)
            %LORAPHY Construct an instance of this class
            self.sf = sf;
            self.bw = bw;
            self.fs = fs;
            self.has_header = 1;
            self.crc = 1;
            self.is_debug = false;
            self.hamming_decoding_en = true;
            self.zero_padding_ratio = 10;
            self.cfo = 0;

            % The whitening sequence is generated by an LFSR
            % x^8+x^6+x^5+x^4+1
            % Use the code below to generate such sequence
            %%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
            % reg = 0xFF;
            % for i = 1:255
            %     fprintf("0x%x, ", reg);
            %     reg = bitxor(bitshift(reg,1), bitxor(bitget(reg,8), bitxor(bitget(reg,6), bitxor(bitget(reg,5), bitget(reg,4)))));
            % end
            %%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
            self.whitening_seq = uint8([0xff, 0xfe, 0xfc, 0xf8, 0xf0, 0xe1, 0xc2, 0x85, 0xb, 0x17, 0x2f, 0x5e, 0xbc, 0x78, 0xf1, 0xe3, 0xc6, 0x8d, 0x1a, 0x34, 0x68, 0xd0, 0xa0, 0x40, 0x80, 0x1, 0x2, 0x4, 0x8, 0x11, 0x23, 0x47, 0x8e, 0x1c, 0x38, 0x71, 0xe2, 0xc4, 0x89, 0x12, 0x25, 0x4b, 0x97, 0x2e, 0x5c, 0xb8, 0x70, 0xe0, 0xc0, 0x81, 0x3, 0x6, 0xc, 0x19, 0x32, 0x64, 0xc9, 0x92, 0x24, 0x49, 0x93, 0x26, 0x4d, 0x9b, 0x37, 0x6e, 0xdc, 0xb9, 0x72, 0xe4, 0xc8, 0x90, 0x20, 0x41, 0x82, 0x5, 0xa, 0x15, 0x2b, 0x56, 0xad, 0x5b, 0xb6, 0x6d, 0xda, 0xb5, 0x6b, 0xd6, 0xac, 0x59, 0xb2, 0x65, 0xcb, 0x96, 0x2c, 0x58, 0xb0, 0x61, 0xc3, 0x87, 0xf, 0x1f, 0x3e, 0x7d, 0xfb, 0xf6, 0xed, 0xdb, 0xb7, 0x6f, 0xde, 0xbd, 0x7a, 0xf5, 0xeb, 0xd7, 0xae, 0x5d, 0xba, 0x74, 0xe8, 0xd1, 0xa2, 0x44, 0x88, 0x10, 0x21, 0x43, 0x86, 0xd, 0x1b, 0x36, 0x6c, 0xd8, 0xb1, 0x63, 0xc7, 0x8f, 0x1e, 0x3c, 0x79, 0xf3, 0xe7, 0xce, 0x9c, 0x39, 0x73, 0xe6, 0xcc, 0x98, 0x31, 0x62, 0xc5, 0x8b, 0x16, 0x2d, 0x5a, 0xb4, 0x69, 0xd2, 0xa4, 0x48, 0x91, 0x22, 0x45, 0x8a, 0x14, 0x29, 0x52, 0xa5, 0x4a, 0x95, 0x2a, 0x54, 0xa9, 0x53, 0xa7, 0x4e, 0x9d, 0x3b, 0x77, 0xee, 0xdd, 0xbb, 0x76, 0xec, 0xd9, 0xb3, 0x67, 0xcf, 0x9e, 0x3d, 0x7b, 0xf7, 0xef, 0xdf, 0xbf, 0x7e, 0xfd, 0xfa, 0xf4, 0xe9, 0xd3, 0xa6, 0x4c, 0x99, 0x33, 0x66, 0xcd, 0x9a, 0x35, 0x6a, 0xd4, 0xa8, 0x51, 0xa3, 0x46, 0x8c, 0x18, 0x30, 0x60, 0xc1, 0x83, 0x7, 0xe, 0x1d, 0x3a, 0x75, 0xea, 0xd5, 0xaa, 0x55, 0xab, 0x57, 0xaf, 0x5f, 0xbe, 0x7c, 0xf9, 0xf2, 0xe5, 0xca, 0x94, 0x28, 0x50, 0xa1, 0x42, 0x84, 0x9, 0x13, 0x27, 0x4f, 0x9f, 0x3f, 0x7f]');

            self.header_checksum_matrix = gf([
                1 1 1 1 0 0 0 0 0 0 0 0
                1 0 0 0 1 1 1 0 0 0 0 1
                0 1 0 0 1 0 0 1 1 0 1 0
                0 0 1 0 0 1 0 1 0 1 1 1
                0 0 0 1 0 0 1 0 1 1 1 1
            ]);

            self.crc_generator = comm.CRCGenerator('Polynomial','X^16 + X^12 + X^5 + 1');

            self.preamble_len = 6;

            self.init();
        end

        function init(self)
            self.bin_num = 2^self.sf*self.zero_padding_ratio;
            self.sample_num = 2*2^self.sf;
            self.fft_len = self.sample_num*self.zero_padding_ratio;

            self.downchirp = LoRaPHY.chirp(false, self.sf, self.bw, 2*self.bw, 0, self.cfo, 0);
            self.upchirp = LoRaPHY.chirp(true, self.sf, self.bw, 2*self.bw, 0, self.cfo, 0);

            % if the chirp peird is larger than 16ms
            % the least significant two bits are considered unreliable and
            % are neglected
            if 2^(self.sf)/self.bw > 16e-3
                self.ldr = 1;
            else
                self.ldr = 0;
            end
        end

        function pk = dechirp(self, x, is_up)
            if nargin == 3 && ~is_up
                c = self.upchirp;
            else
                c = self.downchirp;
            end
            ft = fft(self.sig(x:x+self.sample_num-1).*c, self.fft_len);
            ft_ = abs(ft(1:self.bin_num)) + abs(ft(self.fft_len-self.bin_num+1:self.fft_len));
            pk = LoRaPHY.topn([ft_ (1:self.bin_num).'], 1);
        end

        % Detect preamble
        function x = detect(self, start_idx)
            ii = start_idx;
            pk_bin_list = []; % preamble peak bin list
            while ii < length(self.sig)-self.sample_num*self.preamble_len
                % search preamble_len-1 basic upchirps
                if length(pk_bin_list) == self.preamble_len - 1
                    % preamble detected
                    x = ii;
                    return;
                end
                pk0 = self.dechirp(ii);
                if ~isempty(pk_bin_list)
                    bin_diff = mod(pk_bin_list(end)-pk0(2), self.bin_num);
                    if bin_diff > self.bin_num/2
                        bin_diff = self.bin_num - bin_diff;
                    end
                    if bin_diff <= self.zero_padding_ratio
                        pk_bin_list = [pk_bin_list; pk0(2)];
                    else
                        pk_bin_list = pk0(2);
                    end
                else
                    pk_bin_list = pk0(2);
                end
                ii = ii + self.sample_num;
            end
            x = -1;
        end

        function [symbols_m, cfo_m] = demodulate(self, sig)
            self.init();

            % resample signal with 2*bandwidth
            self.sig = resample(sig, 2*self.bw, self.fs);

            symbols_m = [];
            cfo_m = [];
            x = 1;
            while x < length(self.sig)
                x = self.detect(x);
                if x < 0
                    break;
                end

                % align symbols with SFD
                x = self.sync(x);

                % the goal is to extract payload_len from PHY header
                % header is in the first 8 symbols
                symbols = [];
                pk_list = [];
                for ii = 0:7
                    pk = self.dechirp(x+ii*self.sample_num);
                    pk_list = [pk_list; pk];
                    symbols = [symbols; mod((pk(2)+self.bin_num-self.preamble_bin)/self.zero_padding_ratio, 2^self.sf)];
                end
                if self.has_header
                    is_valid = self.parse_header(round(symbols));
                    if ~is_valid
                        x = x + 7*self.sample_num;
                        continue;
                    end
                end

                % symbol number of the packet
                sym_num = self.calc_sym_num(self.payload_len);

                % demodulate the rest LoRa data symbols
                for ii = 8:sym_num-1
                    pk = self.dechirp(x+ii*self.sample_num);
                    pk_list = [pk_list; pk];
                    symbols = [symbols; mod((pk(2)+self.bin_num-self.preamble_bin)/self.zero_padding_ratio, 2^self.sf)];
                end
                x = x + sym_num*self.sample_num;

                if self.preamble_bin > self.bin_num / 2
                    pkt_cfo = (self.preamble_bin-self.bin_num)*self.bw/self.bin_num;
                else
                    pkt_cfo = self.preamble_bin*self.bw/self.bin_num;
                end
                
                % compensate CFO drift
                symbols = self.dynamic_compensation(symbols);

                symbols_m = [symbols_m mod(round(symbols),2^self.sf)];
                cfo_m = [cfo_m pkt_cfo];
            end

            if isempty(symbols_m)
                warning('No preamble detected!');
            end
        end

        function is_valid = parse_header(self, din)
            % compensate CFO drift
            symbols = self.dynamic_compensation(din);

            % gray coding
            symbols_g = self.gray_coding(symbols);

            % deinterleave
            codewords = self.diag_deinterleave(symbols_g(1:8), self.sf-2);
            % parse header
            nibbles = self.hamming_decode(codewords, 8);
            self.payload_len = double(nibbles(1)*16 + nibbles(2));
            self.crc = double(bitand(nibbles(3), 1));
            self.cr = double(bitshift(nibbles(3), -1));
            % we only calculate header checksum on the first three nibbles
            % the valid header checksum is considered to be 5 bits
            % other 3 bits require further reverse engineering
            header_checksum = [bitand(nibbles(4), 1); de2bi(nibbles(5), 4, 'left-msb')'];
            header_checksum_calc = self.header_checksum_matrix * gf(reshape(de2bi(nibbles(1:3), 4, 'left-msb')', [], 1));
            if any(header_checksum ~= header_checksum_calc)
                warning('Invalid header checksum!');
                is_valid = 0;
            else
                is_valid = 1;
            end
        end

        function s = modulate(self, symbols)
            uc = LoRaPHY.chirp(true, self.sf, self.bw, self.fs, 0, self.cfo, 0);
            dc = LoRaPHY.chirp(false, self.sf, self.bw, self.fs, 0, self.cfo, 0);
            preamble = repmat(uc, self.preamble_len, 1);
            netid = [LoRaPHY.chirp(true, self.sf, self.bw, self.fs, 24, self.cfo, 0); LoRaPHY.chirp(true, self.sf, self.bw, self.fs, 32, self.cfo, 0)];

            chirp_len = length(uc);
            sfd = [dc; dc; dc(1:round(chirp_len/4))];
            data = zeros(length(symbols)*chirp_len, 1);
            for i = 1:length(symbols)
                data((i-1)*chirp_len+1:i*chirp_len) =  LoRaPHY.chirp(true, self.sf, self.bw, self.fs, symbols(i), self.cfo, 0);
            end
            s = [preamble; netid; sfd; data];
        end

        function symbols = encode(self, payload)
            if self.crc
                data = uint8([payload; self.calc_crc(payload)]);
            else
                data = uint8(payload);
            end

            plen = length(payload);
            sym_num = self.calc_sym_num(plen);
            % filling all symbols needs nibble_num nibbles
            nibble_num = self.sf - 2 + (sym_num-8)/(self.cr+4)*(self.sf-2*self.ldr);
            data_w = uint8([data; zeros(ceil((nibble_num-2*length(data))/2), 1)]);
            data_w(1:plen) = self.whiten(data_w(1:plen));
            data_nibbles = uint8(zeros(nibble_num, 1));
            for i = 1:nibble_num
                idx = ceil(i/2);
                if mod(i, 2) == 1
                    data_nibbles(i) = bitand(data_w(idx), 0xf);
                else
                    data_nibbles(i) = bitshift(data_w(idx), -4);
                end
            end

            if self.has_header
                header_nibbles = self.gen_header(plen);
            else
                header_nibbles = [];
            end
            codewords = self.hamming_encode([header_nibbles; data_nibbles]);

            % interleave
            % first 8 symbols use CR=4/8
            symbols_i = self.diag_interleave(codewords(1:self.sf-2), 8);
            ppm = self.sf - 2*self.ldr;
            rdd = self.cr + 4;
            for i = self.sf-1:ppm:length(codewords)-ppm+1
                symbols_i = [symbols_i; self.diag_interleave(codewords(i:i+ppm-1), rdd)];
            end

            symbols = self.gray_decoding(symbols_i);
        end

        function header_nibbles = gen_header(self, plen)
            header_nibbles = zeros(5, 1);
            header_nibbles(1) = bitshift(plen, -4);
            header_nibbles(2) = bitand(plen, 15);
            header_nibbles(3) = bitor(2*self.cr, self.crc);
            header_checksum = self.header_checksum_matrix * gf(reshape(de2bi(header_nibbles(1:3), 4, 'left-msb')', [], 1));
            x = header_checksum.x;
            header_nibbles(4) = x(1);
            for i = 1:4
                header_nibbles(5) = bitor(header_nibbles(5), x(i+1)*2^(4-i));
            end
        end

        function checksum = calc_crc(self, din)
            input = din(1:end-2);
            seq = self.crc_generator(reshape(logical(de2bi(input, 8, 'left-msb'))', [], 1));
            checksum_b1 = bitxor(bi2de(seq(end-7:end)', 'left-msb'), din(end));
            checksum_b2 = bitxor(bi2de(seq(end-15:end-8)', 'left-msb'), din(end-1));
            checksum = [checksum_b1; checksum_b2];
        end

        function data_w = whiten(self, data)
            len = length(data);
            data_w = bitxor(data(1:len), self.whitening_seq(1:len));
            self.print_bin("Whiten", data_w);
        end

        function codewords = hamming_encode(self, nibbles)
            nibble_num = length(nibbles);
            codewords = uint8(zeros(nibble_num, 1));
            for i = 1:nibble_num
                nibble = nibbles(i);

                p1 = LoRaPHY.bit_reduce(@bitxor, nibble, [1 3 4]);
                p2 = LoRaPHY.bit_reduce(@bitxor, nibble, [1 2 4]);
                p3 = LoRaPHY.bit_reduce(@bitxor, nibble, [1 2 3]);
                p4 = LoRaPHY.bit_reduce(@bitxor, nibble, [1 2 3 4]);
                p5 = LoRaPHY.bit_reduce(@bitxor, nibble, [2 3 4]);
                if i <= self.sf - 2
                    % the first SF-2 nibbles use CR=4/8
                    cr_now = 4;
                else
                    cr_now = self.cr;
                end
                switch cr_now
                    case 1
                        codewords(i) = bitor(uint8(p4)*16, nibble);
                    case 2
                        codewords(i) = LoRaPHY.word_reduce(@bitor, [uint8(p5)*32 uint8(p3)*16 nibble]);
                    case 3
                        codewords(i) = LoRaPHY.word_reduce(@bitor, [uint8(p2)*64 uint8(p5)*32 uint8(p3)*16 nibble]);
                    case 4
                        codewords(i) = LoRaPHY.word_reduce(@bitor, [uint8(p1)*128 uint8(p2)*64 uint8(p5)*32 uint8(p3)*16 nibble]);
                    otherwise
                        % THIS CASE SHOULD NOT HAPPEN
                        error('Invalid Code Rate!');
                end
            end
        end

        function symbols_i = diag_interleave(self, codewords, rdd)
            tmp = de2bi(codewords, rdd, 'right-msb');
            symbols_i = uint16(bi2de(cell2mat(arrayfun(@(x) circshift(tmp(:,x), 1-x), 1:rdd, 'un', 0))'));
            self.print_bin("Interleave", symbols_i);
        end

        function symbols = gray_decoding(self, symbols_i)
            symbols = zeros(length(symbols_i), 1);
            for i = 1:length(symbols_i)
                num = uint16(symbols_i(i));
                mask = bitshift(num, -1);
                while mask ~= 0
                    num = bitxor(num, mask);
                    mask = bitshift(mask, -1);
                end
                if i <= 8 || self.ldr
                    symbols(i) = mod(num * 4 + 1, 2^self.sf);
                else
                    symbols(i) = mod(num + 1, 2^self.sf);
                end
            end
        end

        function sym_num = calc_sym_num(self, plen)
            sym_num = double(8 + max((4+self.cr)*ceil(double((2*plen-self.sf+7+4*self.crc-5*(1-self.has_header)))/double(self.sf-2*self.ldr)), 0));
        end

        function plen = calc_payload_len(self, slen, no_redundant_bytes)
            if nargin < 3
                no_redundant_bytes = false;
            end
            % plen_float possibly has fractional part 0.5, which means
            % there would be 0.5 uncontrollable redundant byte in a packet.
            % The 0.5 byte results in unexpected symbols when called by
            % function `symbols_to_bytes`. To make all specified symbols
            % controllable, we use `ceil` instead of `floor` when
            % no_redundant_bytes is true.
            plen_float = (self.sf-2)/2 - 2.5*self.has_header + (self.sf-self.ldr*2)/2 * ceil((slen-8)/(self.cr+4));
            if no_redundant_bytes
                plen = ceil( plen_float );
            else
                plen = floor( plen_float );
            end
        end

        function dout = sync(self, x)
            % find downchirp
            found = false;
            while x < length(self.sig) - self.sample_num
                up_peak = self.dechirp(x);
                down_peak = self.dechirp(x, false);
                if abs(down_peak(1)) > abs(up_peak(1))
                    % downchirp detected
                    found = true;
                end
                x = x + self.sample_num;
                if found
                    break;
                end
            end

            if ~found
                return;
            end

            % up-down alignment
            % NOTE preamble_len >= 6
            % NOTE there are two NETID chirps between preamble and SFD
            x_u = x - 4*self.sample_num;
            pku = self.dechirp(x_u);
            % first shift the up peak to position 0
            % current sampling frequency = 2 * bandwidth
            x = x - round((pku(2)-1)/self.zero_padding_ratio*2);

            pkd = self.dechirp(x, false);
            if pkd(2) > self.bin_num / 2
                to = round((pkd(2)-1-self.bin_num)/self.zero_padding_ratio);
            else
                to = round((pkd(2)-1)/self.zero_padding_ratio);
            end
            x = x + to;

            % set preamble reference bin for CFO elimination
            pku = self.dechirp(x - 4*self.sample_num);
            self.preamble_bin = pku(2);

            % set x to the start of data symbols
            pku = self.dechirp(x-self.sample_num);
            pkd = self.dechirp(x-self.sample_num, false);
            if abs(pku(1)) > abs(pkd(1))
                % current symbol is the first downchirp
                dout = x + round(2.25*self.sample_num);
            else
                % current symbol is the second downchirp
                dout = x + round(1.25*self.sample_num);
            end
        end

        function [data_m, checksum_m] = decode(self, symbols_m)
            data_m = [];
            checksum_m = [];

            for pkt_num = 1:size(symbols_m, 2)
                % gray coding
                symbols_g = self.gray_coding(symbols_m(:, pkt_num));

                % deinterleave
                codewords = self.diag_deinterleave(symbols_g(1:8), self.sf-2);
                if ~self.has_header
                    nibbles = self.hamming_decode(codewords, 8);
                else
                    % parse header
                    nibbles = self.hamming_decode(codewords, 8);
                    self.payload_len = double(nibbles(1)*16 + nibbles(2));
                    self.crc = double(bitand(nibbles(3), 1));
                    self.cr = double(bitshift(nibbles(3), -1));
                    % we only calculate header checksum on the first three nibbles
                    % the valid header checksum is considered to be 5 bits
                    % other 3 bits require further reverse engineering
                    header_checksum = [bitand(nibbles(4), 1); de2bi(nibbles(5), 4, 'left-msb')'];
                    header_checksum_calc = self.header_checksum_matrix * gf(reshape(de2bi(nibbles(1:3), 4, 'left-msb')', [], 1));
                    if any(header_checksum ~= header_checksum_calc)
                        error('Invalid header checksum!');
                    end
                    nibbles = nibbles(6:end);
                end
                rdd = self.cr + 4;
                for ii = 9:rdd:length(symbols_g)-rdd+1
                    codewords = self.diag_deinterleave(symbols_g(ii:ii+rdd-1), self.sf-2*self.ldr);
                    % hamming decode
                    nibbles = [nibbles; self.hamming_decode(codewords, rdd)];
                end

                % combine nibbles to bytes
                bytes = uint8(zeros(min(255, floor(length(nibbles)/2)), 1));
                for ii = 1:length(bytes)
                    bytes(ii) = bitor(uint8(nibbles(2*ii-1)), 16*uint8(nibbles(2*ii)));
                end

                % dewhitening
                len = self.payload_len;
                if self.crc
                    % The last 2 bytes are CRC16 checkcum
                    data = [self.dewhiten(bytes(1:len)); bytes(len+1:len+2)];
                    % Calculate CRC checksum
                    checksum = self.calc_crc(data(1:len));
                else
                    data = self.dewhiten(bytes(1:len));
                    checksum = [];
                end
                data_m = [data_m data];
                checksum_m = [checksum_m checksum];
            end
        end

        function symbols = dynamic_compensation(self, din)
            symbols = zeros(length(din), 1);
            bin_offset = 0;
            
            if self.ldr
                mod_base = 4;
            else
                mod_base = 1;
            end
            
            for i = 1:length(din)
                v = din(i);
                if i == 1
                    last_rem = mod(v, mod_base);
                end
                this_rem = mod(v, mod_base);
                dis = mod(this_rem-last_rem, mod_base);
                if dis < mod_base / 2
                    bin_offset = bin_offset - dis;
                else
                    bin_offset = bin_offset - dis + mod_base;
                end
                last_rem = this_rem;
                symbols(i) = mod(v+bin_offset, 2^self.sf);
            end
        end

        function symbols = gray_coding(self, din)
            din(1:8) = floor(din(1:8)/4);
            if self.ldr
                din(9:end) = floor(din(9:end)/4);
            else
                din(9:end) = mod(din(9:end)-1, 2^self.sf);
            end
            s = uint16(din);
            symbols = bitxor(s, bitshift(s, -1));
            self.print_bin("Gray Coding", symbols, self.sf);
        end

        function codewords = diag_deinterleave(self, symbols, ppm)
            b = de2bi(symbols, double(ppm), 'left-msb');
            codewords = flipud(bi2de(cell2mat(arrayfun(@(x) ...
                circshift(b(x,:), [1 1-x]), (1:length(symbols))', 'un', 0))'));
            self.print_bin("Deinterleave", codewords);
        end

        function bytes_w = dewhiten(self, bytes)
            len = length(bytes);
            bytes_w = bitxor(uint8(bytes(1:len)), self.whitening_seq(1:len));
            self.print_bin("Dewhiten", bytes_w);
        end

        function nibbles = hamming_decode(self, codewords, rdd)
            p1 = LoRaPHY.bit_reduce(@bitxor, codewords, [8 4 3 1]);
            p2 = LoRaPHY.bit_reduce(@bitxor, codewords, [7 4 2 1]);
            p3 = LoRaPHY.bit_reduce(@bitxor, codewords, [5 3 2 1]);
            p4 = LoRaPHY.bit_reduce(@bitxor, codewords, [5 4 3 2 1]);
            p5 = LoRaPHY.bit_reduce(@bitxor, codewords, [6 4 3 2]);
            function pf = parity_fix(p)
                switch p
                    case 3 % 011 wrong b3
                        pf = 4;
                    case 5 % 101 wrong b4
                        pf = 8;
                    case 6 % 110 wrong b1
                        pf = 1;
                    case 7 % 111 wrong b2
                        pf = 2;
                    otherwise
                        pf = 0;
                end
            end
            if self.hamming_decoding_en
                switch rdd
                    % TODO report parity error
                    case {5, 6}
                        nibbles = mod(codewords, 16);
                    case {7, 8}
                        parity = p2*4+p3*2+p5;
                        pf = arrayfun(@parity_fix, parity);
                        codewords = bitxor(codewords, uint16(pf));
                        nibbles = mod(codewords, 16);
                    otherwise
                        % THIS CASE SHOULD NOT HAPPEN
                        error('Invalid Code Rate!');
                end
            else
                nibbles = mod(codewords, 16);
            end
            self.print_bin("Hamming Decode", codewords);
        end

        function bytes = symbols_to_bytes(self, symbols)
            symbols = reshape(symbols, [length(symbols), 1]);
            self.init();
            self.hamming_decoding_en = false;
            payload_len_ = self.payload_len;

            if length(symbols) <= 4
                slen_tmp = 8 + self.has_header*(self.cr+4);
            else
                slen_tmp = 8 + ceil((length(symbols)-4*(1-self.has_header))/4) * (self.cr+4);
            end
            self.payload_len = self.calc_payload_len(slen_tmp, true);
            symbols_ = zeros(self.calc_sym_num(self.payload_len), 1);
            if self.has_header
                jj = 9;
            else
                jj = 1;
            end
            for ii = 1:4:length(symbols)
                if ii+3 <= length(symbols)
                    symbols_(jj:jj+3) = symbols(ii:ii+3);
                else
                    symbols_(jj:jj+3) = [symbols(ii:end); zeros(ii-length(symbols)+3, 1)];
                end
                if jj == 1
                    jj = 9;
                else
                    jj = jj + self.cr + 4;
                end
            end
            if self.has_header
                % construct header
                symbols_tmp = self.encode(zeros(self.payload_len, 1));
                symbols_(1:8) = symbols_tmp(1:8);
            end
            [bytes, ~] = self.decode(symbols_);
            if self.crc
                bytes = bytes(1:end-2);
            end

            self.hamming_decoding_en = true;
            self.payload_len = payload_len_;
        end

        function print_bin(ld, flag, vec, size)
            if ld.is_debug
                if nargin == 3
                    size = 8;
                end
                len = length(vec);
                fprintf("%s:\n", flag);
                for i = 1:len
                    fprintf("%s\n", dec2bin(round(vec(i)), size));
                end
                fprintf("\n");
            end
        end

        function print_hex(ld, flag, vec)
            if ld.is_debug
                len = length(vec);
                fprintf("%s: ", flag);
                for i = 1:len
                    fprintf("%s ", dec2hex(round(vec(i))));
                end
                fprintf("\n");
            end
        end

        function log(ld, flag, data)
            if ld.is_debug
                fprintf("%s: ", flag);
                len = length(data);
                for i = 1:len
                    fprintf("%d ", data(i));
                end
                fprintf("\n");
            end
        end
    end

    methods(Static)
        function b = bit_reduce(fn, w, pos)
            b = bitget(w, pos(1));
            for i = 2:length(pos)
                b = fn(b, bitget(w, pos(i)));
            end
        end

        function w = word_reduce(fn, ws)
            w = ws(1);
            for i = 2:length(ws)
                w = fn(w, ws(i));
            end
        end

        function y = topn(pks, n, padding, th)
            [y, p] = sort(abs(pks(:,1)), 'descend');
            if nargin == 1
                return;
            end
            nn = min(n, size(pks, 1));
            if nargin >= 3 && padding
                y = [pks(p(1:nn), :); zeros(n-nn, size(pks, 2))];
            else
                y = pks(p(1:nn), :);
            end
            if nargin == 4
                ii = 1;
                while ii <= size(y,1)
                    if abs(y(ii,1)) < th
                        break;
                    end
                    ii = ii + 1;
                end
                y = y(1:ii-1, :);
            end
        end

        function y = chirp(isup, sf, bw, fs, h, cfo, tdelta)
            if nargin < 7
                tdelta = 0;
            end
            if nargin < 6
                cfo = 0;
            end
            N = 2^sf;
            T = N/bw;
            samp_per_sym = round(fs/bw*N);
            h_orig = h;
            h = round(h);
            cfo = cfo + (h_orig - h) / N * bw;
            if isup
                k = bw/T;
                f0 = -bw/2+cfo;
            else
                k = -bw/T;
                f0 = bw/2+cfo;
            end

            % retain last element to calculate phase
            t = (0:samp_per_sym*(N-h)/N)/fs + tdelta;
            snum = length(t);
            c1 = exp(1j*2*pi*(t.*(f0+k*T*h/N+0.5*k*t)));

            if snum == 0
                phi = 0;
            else
                phi = angle(c1(snum));
            end
            t = (0:samp_per_sym*h/N-1)/fs + tdelta;
            c2 = exp(1j*(phi + 2*pi*(t.*(f0+0.5*k*t))));

            y = cat(2, c1(1:snum-1), c2).';
        end
    end
end
