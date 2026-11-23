# 2단계: Zynq PS(ARM) + 카메라 경로 통합

1단계의 카메라 → TFT-LCD 경로(PL, VHDL)를 **ARM(PS)이 들어간 Zynq 시스템** 안으로 옮긴 설계.
ARM에서는 Hello World가 UART로 계속 출력되고, 동시에 FPGA 쪽 카메라 영상이 TFT-LCD에 나온다.

- 보드: HUINS RPS-Z7020-TK (Zynq XC7Z020-CLG484-1)
- 툴: Vivado / SDK 2019.1
- 상태: **동작 확인 완료 (2026-11-23)** — UART `Hello World 0`~`78` 수신 + TFT 카메라 영상

> 저장소는 반드시 **영문 경로**에 clone 한다 (Vivado 2019.1 한글 경로 크래시).

---

## 구조

```
term_top.vhd (최상위)
 ├─ system_wrapper   ← 블록 디자인 "system": ZYNQ7 Processing System 하나
 │                      UART1 (MIO 48..49, 1.8V), DDR 끔, M_AXI_GP0 끔
 └─ camera_top       ← 1단계 카메라 경로 그대로 (OV5640 → BRAM → TFT, LED 진단)
```

- 블록 디자인에는 PS만 넣고, **손으로 쓴 최상위(term_top.vhd)** 가 PS와 카메라 모듈을 나란히 불러온다. (ch10 인터럽트 실습과 같은 방식. VHDL 모듈을 블록 디자인 안에 넣는 것보다 에러가 적다.)
- 1단계 top의 `resetn`(PB0, Y18)은 실제로 쓰이지 않아서 제거했다. **PB0이 비어서** 나중에 입력 버튼으로 쓸 수 있다.
- ARM과 카메라 경로는 아직 서로 연결되지 않았다. 연결(AXI capture IP)은 3단계.

---

## 폴더 구성

| 경로 | 내용 |
|---|---|
| `src/term_top.vhd` | 최상위 (PS wrapper + camera_top) |
| `src/camera_top.vhd` + VHDL 6개 | 1단계 카메라 경로 (`top` → `camera_top`으로 이름만 변경, resetn 제거) |
| `src/ip/RAM_camera/` | 블록 메모리 IP |
| `src/top.xdc` | 핀 제약 (1단계에서 resetn 줄 제거) |
| `src/system_bd.tcl` | 블록 디자인(PS 설정 포함)을 만드는 Tcl |
| `sdk_src/helloworld.c` | ARM 프로그램: UART1 켜기 + `Hello World N` 무한 출력 |
| `bitstream/term_top.bit` | **바로 구울 수 있는 비트스트림** |
| `bitstream/term_top.hdf` | SDK용 하드웨어 파일 (비트스트림 포함) |
| `bitstream/ps7_init.tcl` | PS 초기화 스크립트 (SDK hw_platform에서 복사) |
| `bitstream/hello.elf` | **바로 실행할 수 있는 ARM 프로그램** |
| `create_project.tcl` | 위 소스로 Vivado 프로젝트(`vivado/stage2.xpr`) 생성 |
| `build.tcl` | 비트스트림 빌드 + hdf 내보내기 → `bitstream/`에 복사 |
| `program.tcl` | FPGA만 굽기 (이미 구워져 있으면 건너뜀) |
| `run_hello.tcl` | FPGA 굽기 → PS 초기화 → hello.elf 실행까지 한 번에 |

`vivado/` 폴더(프로젝트, 빌드 결과)는 `create_project.tcl`로 다시 만들 수 있어서 저장소에 올리지 않는다.

---

## 바로 실행하기 (빌드 없이)

1. 보드 준비: 카메라 CAMERA1(J23)에 꽂기(번호 맞춰서), **DIP SW1-1 ON**, JTAG 연결, 보드 전원 ON
2. UART USB 연결 → 장치 관리자에서 COM 번호 확인
3. 터미널(SDK Terminal, PuTTY, Tera Term 등)을 **COM 포트, 115200**으로 열기
4. 실행
   ```bat
   C:\Xilinx\SDK\2019.1\bin\xsct.bat run_hello.tcl
   ```
5. 터미널에 `Hello World 0, 1, 2...`, TFT에 카메라 영상이 나오면 성공

---

## Vivado / SDK로 직접 하기

### 프로젝트 만들기
```bat
cd stage2_ps
C:\Xilinx\Vivado\2019.1\bin\vivado.bat -mode batch -source create_project.tcl
```
→ `vivado/stage2.xpr` 를 Vivado GUI로 열면 된다. 최상위는 `term_top`.

### 비트스트림
- GUI: Generate Bitstream
- 명령어: `vivado.bat -mode batch -source build.tcl` (끝나면 `bitstream/`에 bit, hdf 갱신)
- GUI에서 `ai_engine` 관련 에러가 나면: Sources에서 `system` 우클릭 → Generate Output Products 먼저 → Generate Bitstream

### SDK
1. File → Export → Export Hardware → **Include bitstream** → Local to Project
2. File → Launch SDK
3. New → Application Project → 이름 `hello` → Hello World 템플릿
4. `src/helloworld.c` 내용을 **`sdk_src/helloworld.c`로 교체** (템플릿 그대로는 출력이 안 나온다. 아래 참고)
5. **FPGA는 먼저 따로 굽는다** (Hardware Manager 또는 `program.tcl`)
6. Debug Configurations → Target Setup
   - **Reset entire system: 해제**
   - **Program FPGA: 해제**
   - Run ps7_init, Run ps7_post_config: 체크
7. Debug → Resume(F8)

---

## 주의사항 (2026-11-23 실제로 겪은 것)

| 문제 | 원인 / 해결 |
|---|---|
| SDK Hello World 템플릿이 아무것도 안 찍음 | JTAG로 올리면 UART 송신(TX)이 꺼져 있다. `sdk_src/helloworld.c`처럼 UART1 CR 레지스터에 TX_EN/RX_EN을 먼저 쓴다 (9/28 실습 main.c와 동일) |
| `fpga configuration failed. DONE PIN is not HIGH` | 이미 구워진 FPGA를 **전원 재투입 없이 다시 구울 때**, SDK `Reset entire system` 직후 구울 때 발생. **전원 한 번 켤 때 굽기는 한 번만** |
| 굽기 실패 직후 `APU (JTAG port open error. AP transaction timeout)` | 굽기가 실패하면 ARM이 잠긴다. **보드 전원 재투입**으로만 풀린다 |
| JTAG에 `xc7z020`만 있고 `arm_dap` 없음 | Independent JTAG 모드 증상(J19/MIO2). J19 재삽입 1회 시도 → 안 되면 **보드 교체**. 첫 번째 보드는 결국 교체로 해결 |

자세한 경과는 저장소 루트 [`README.md`](../README.md) 참고.
