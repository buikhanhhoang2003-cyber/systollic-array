`timescale 1ns / 1ps

module speed_select(
				clk,rst_n,
				bps_start,clk_bps
			);

input clk;	// 50MHz��ʱ��
input rst_n;	//�͵�ƽ��λ�ź�
input bps_start;	//���յ����ݺ󣬲�����ʱ�������ź���λ
output clk_bps;	// clk_bps�ĸߵ�ƽΪ���ջ��߷�������λ���м������ 

/*
parameter 		bps9600 	= 5207,	//������Ϊ9600bps
			 	bps19200 	= 2603,	//������Ϊ19200bps
				bps38400 	= 1301,	//������Ϊ38400bps
				bps57600 	= 867,	//������Ϊ57600bps
				bps115200	= 433;	//������Ϊ115200bps

parameter 		bps9600_2 	= 2603,
				bps19200_2	= 1301,
				bps38400_2	= 650,
				bps57600_2	= 433,
				bps115200_2 = 216;  
*/

	//���²����ʷ�Ƶ����ֵ�ɲ�������Ĳ������и���
`define		BPS_PARA		5207	//������Ϊ9600ʱ�ķ�Ƶ����ֵ
`define 	BPS_PARA_2		2603	//������Ϊ9600ʱ�ķ�Ƶ����ֵ��һ�룬�������ݲ���

reg[12:0] cnt;			//��Ƶ����
reg clk_bps_r;			//������ʱ�ӼĴ���

//----------------------------------------------------------
reg[2:0] uart_ctrl;	// uart������ѡ��Ĵ���
//----------------------------------------------------------

always @ (posedge clk or negedge rst_n)
	if(!rst_n) cnt <= 13'd0;
	else if((cnt == `BPS_PARA) || !bps_start) cnt <= 13'd0;	//�����ʼ�������
	else cnt <= cnt+1'b1;			//������ʱ�Ӽ�������

always @ (posedge clk or negedge rst_n)
	if(!rst_n) clk_bps_r <= 1'b0;
//����һ��������&& bps_start��
	else if(cnt == `BPS_PARA_2 && bps_start) clk_bps_r <= 1'b1;	// clk_bps_r�ߵ�ƽΪ��������λ���м������,ͬʱҲ��Ϊ�������ݵ����ݸı��
	else clk_bps_r <= 1'b0;

assign clk_bps = clk_bps_r;

endmodule



