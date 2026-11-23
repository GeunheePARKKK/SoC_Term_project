# 1단계: OV5640 카메라 → FPGA → TFT-LCD 실시간 영상

PS(ARM) 없이 **PL(FPGA)만으로** OV5640 카메라 영상을 4.3인치 TFT-LCD에 띄우는 설계.
텀 프로젝트(카메라 기반 소형 AI 검색대)의 하드웨어 검증 단계이며, 2단계 이후 카메라 경로의 출발점이다.

- 보드: HUINS RPS-Z7020-TK (Zynq XC7Z020-CLG484-1)
- 툴: Vivado 2019.1 (원본은 강의자료 ch13_pl_cis, Vivado 2014.4 프로젝트를 2019.1로 변환)
- 언어: VHDL
- 상태: **동작 확인 완료 (2026-11-16)**

> 폴더 이름을 `1단계`가 아니라 `stage1_camera`로 한 이유: Vivado 2019.1은 경로에 한글이 있으면 합성 중 크래시가 난다 (`TclStackFree: incorrect freePtr`). 이 저장소도 반드시 **영문 경로**(예: `C:\workspace_SoC\SoC_Term_project`)에 clone 할 것.

---

## 폴더 구성

| 경로 | 내용 |
|---|---|
| `bitstream/top.bit` | **바로 구울 수 있는 완성 비트스트림** |
| `ch13_pl_cis.xpr` | Vivado 프로젝트 파일 (코드 수정 후 다시 빌드할 때만 사용) |
| `ch13_pl_cis.srcs/sources_1/new/` | VHDL 소스 7개 |
| `ch13_pl_cis.srcs/sources_1/ip/RAM_camera/` | 블록 메모리 IP (128K x 16bit 듀얼포트, blk_mem_gen 8.4) |
| `ch13_pl_cis.srcs/constrs_1/new/top.xdc` | 핀 제약 |
| `build.tcl` | 배치 빌드 스크립트 (GUI 없이 비트스트림 생성) |
| `program.tcl` | xsct로 비트스트림 굽기 스크립트 |

### VHDL 모듈

| 파일 | 역할 |
|---|---|
| `top.vhd` | 최상위. 모듈 연결, 카메라 MCLK/TFT 제어 신호, **LED 진단 로직(추가)** |
| `camera_i2c.vhd` | 카메라 전원/리셋 시퀀스 + I2C(SCCB) 설정 상태머신 |
| `camera_i2c_command.vhd` | I2C 비트 단위 전송 |
| `camera_i2c_rom.vhd` | OV5640 레지스터 설정값 ROM (VGA, RGB565, 상하/좌우 반전). **x"6F" 줄 = 테스트 패턴(현재 주석)** |
| `camera_to_RAM.vhd` | 카메라 PCLK/HREF/VSYNC/DATA[7:0] → 2바이트 묶어 RGB565로 480x272 BRAM에 기록 |
| `RAM_to_TFTLCD.vhd` | BRAM 읽어서 TFT 타이밍(Hsync/Vsync) 생성 |
| `clk_generator.vhd` | 25 MHz 분주 (TFT 픽셀 클럭, I2C 클럭) |

### 데이터 흐름

```
OV5640 ──I2C 설정──< camera_i2c (SW1-1로 OV5640 선택)
   │ PCLK, HREF, VSYNC, D[7:0]
   ▼
camera_to_RAM ──(PCLK 도메인 쓰기)──> RAM_camera (BRAM) ──(TFT 클럭 읽기)──> RAM_to_TFTLCD ──> TFT-LCD
```

---

## 혼자 다시 실행하기 (빌드 없이 굽기만)

### 보드 준비 (전원 OFF 상태에서)

1. 카메라를 **CMOS CAMERA1** 커넥터(J23)에 꽂는다. **카메라에 인쇄된 번호와 보드에 인쇄된 번호가 같은 쪽**(예: 19번 = 19번).
2. **GPIO DIP-SW SW1의 1번을 ON** (Y20, OV5640 설정 선택).
3. JTAG 케이블 연결, TFT-LCD 리본 케이블 확인.
4. 전원 ON → **카메라 모듈의 빨간 전원 LED가 켜지는지** 확인. 안 켜지면 전원 끄고 다시 꽂는다.

### 비트스트림 굽기 (GUI)

1. Vivado 2019.1 → **Open Hardware Manager** (프로젝트는 열 필요 없음)
2. **Open target → Auto Connect**
3. `xc7z020_1` 우클릭 → **Program Device** → Bitstream file = `bitstream/top.bit` → **Program**
4. TFT에 카메라 영상이 나오면 성공.

### 비트스트림 굽기 (명령어)

```bat
C:\Xilinx\SDK\2019.1\bin\xsct.bat program.tcl
```
`DONE: FPGA is configured` 가 나오면 성공.

> 보드 전원을 끄면 FPGA 설정이 사라진다. 켤 때마다 다시 굽는다.

---

## 코드를 고쳐서 다시 빌드하기

- GUI: `ch13_pl_cis.xpr` 열기 → **Generate Bitstream** → 결과는 `ch13_pl_cis.runs/impl_1/top.bit` (위 방법으로 굽기)
- 명령어: `C:\Xilinx\Vivado\2019.1\bin\vivado.bat -mode batch -source build.tcl` → 끝나면 `bitstream/top.bit` 자동 갱신 (5~8분)
- IP 업그레이드는 이미 끝난 상태라 프로젝트를 열 때 IP 관련 팝업은 뜨지 않는다.

---

## LED 진단 (원본 ch13에 추가한 기능)

보드의 GPIO LED 8개에 카메라 신호 상태를 표시한다. 화면이 안 나올 때 어디서 끊겼는지 바로 알 수 있다.

| LED | 의미 | 정상 |
|---|---|---|
| D1 | 카메라 PCLK 들어옴 | 깜빡 |
| D2 | VSYNC(프레임) | 깜빡 |
| D3 | HSYNC(라인) | 깜빡 |
| D4 | I2C SCL 활동 | 켜짐 |
| D5 | I2C SDA 활동 | 켜짐 |
| D6 | 카메라 RESETn 해제 | 켜짐 |
| D7 | BRAM에 픽셀 기록됨 | 켜짐 |
| D8 | DIP SW1-1 (OV5640 선택) | 켜짐 |

- 굽는 순간 LED 8개가 잠깐 다 켜지는 건 정상 (설정 중 핀 풀업).
- **D4, D5, D6, D8만 켜지고 D1이 꺼져 있으면** → FPGA는 설정을 보내는데 카메라가 응답 없음 = 카메라 전원/연결/모듈 문제.

### 센서 테스트 패턴

`camera_i2c_rom.vhd` 의 아래 줄 주석을 풀고 다시 빌드하면 OV5640이 직접 만든 컬러바가 나온다. 렌즈와 무관하게 카메라 경로 전체를 검증할 때 사용.
```vhdl
when    x"6F"   =>  i2c_rom_data        <=   x"78503D" & '1' & "000" & x"0";    -- test pattern
```

---

## 원본 ch13 대비 변경점

| 파일 | 변경 |
|---|---|
| `ch13_pl_cis.xpr` | Vivado 2014.4 → 2019.1 자동 업그레이드, 경로를 상대경로로 |
| `RAM_camera` IP | blk_mem_gen 7.3/8.2 → 8.4 업그레이드 |
| `top.vhd` | `use ieee.std_logic_unsigned.all` 추가, LED[7:0] 출력 포트와 진단 로직 추가 (VSYNC/HSYNC는 PCLK로 샘플링해 에지 검출) |
| `top.xdc` | LED[7:0] 핀 추가 (T16, T17, R19, T19, R18, T18, P16, R16) |
| `camera_i2c_rom.vhd` | 변경 없음 (테스트 패턴 줄은 원래대로 주석) |

---

## 문제 해결

| 증상 | 원인 / 해결 |
|---|---|
| 한글 경로 프로젝트에서 `synth_1 Failed`, 로그도 안 생김 | Vivado 한글 경로 버그. 영문 경로로 옮긴다 |
| Auto Connect가 장치를 못 찾음 (`DR shift through all ones/zeroes`) | 보드 전원 확인, JTAG 케이블 재연결, Vivado 재시작 |
| Program 실패 `DONE PIN is not HIGH` | Close Target 후 다시 Open Target, 안 되면 보드 전원 재투입. JTAG 속도를 낮춰둔 상태면 기본 속도(10 MHz)로 |
| TFT가 검다 | 백라이트 문제가 아니라 **영상 데이터가 0**인 것. LED D1 확인 → 카메라 연결/전원 문제 |
| 카메라가 손 못 댈 정도로 뜨거움 | 즉시 전원 OFF. 방향 반대로 꽂힌 것 |
| `[Place 30-876] ... W18 can only be used as the N side of a differential clock input` | VSYNC/HSYNC를 클럭(`process(camera_VSYNC)`)으로 쓰면 발생. PCLK로 샘플링해 에지 검출할 것 |
| JTAG에서 `arm_dap`이 안 보임 | 1단계는 PL만 쓰므로 영향 없음. 2단계(SDK) 전에 해결 → 상위 `README.md` 2단계 시작 전 체크 참고 |

자세한 진행 기록과 Q&A는 저장소 루트의 [`README.md`](../README.md) 1단계 참고.
