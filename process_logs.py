#!/usr/bin/env python
# coding=utf-8
import sys
import os
from os import listdir
from os.path import isfile, join

def main():
    print("cwd", os.getcwd())
    print("sys.argv[1]", sys.argv[1])
    mypath = sys.argv[1]
    csv = "oltp_update_compare_report.csv"

    data = {}
    onlyfiles = [f for f in listdir(mypath) if isfile(join(mypath, f))]
    for file in onlyfiles:
        item = do_file(file, mypath)
        pd = item["pd"]
        kv = item["kv"]
        db = item["db"]
        round = item["round"]

        if not pd in data:
            data[pd] = {}
        if not kv in data[pd]:
            data[pd][kv] = {}
        if not db in data[pd][kv]:
            data[pd][kv][db] = {}
        data[pd][kv][db][round] = item
    calc(data)
    to_csv(data, csv)

def calc(data):
    for pd in data:
        for kv in data[pd]:
            for db in data[pd][kv]:
                extended = {"tps": 0.0, "avg": 0.0, "95th": 0.0}
                n = len(data[pd][kv][db])
                for round in data[pd][kv][db]:
                    extended["tps"] += float(data[pd][kv][db][round]['tps'])
                    extended["avg"] += float(data[pd][kv][db][round]['avg'])
                    extended["95th"] += float(data[pd][kv][db][round]['95th'])
                for k in extended:
                    extended[k] //= n
                data[pd][kv][db].update(extended)

def do_file(file, dir):
    data = {}
    f = open(dir + "/" + file, 'r')
    lines = f.readlines()
    if lines[-20].find("transactions:") == -1:
        print(lines[-20])
    if lines[-9].find("avg:") == -1:
        print(lines[-9])
    if lines[-7].find("95th ") == -1:
        print(lines[-7])

    data["tps"] = lines[-20].strip().split("(")[1].split(" ")[0]
    data["avg"] = lines[-9].strip().split(" ")[-1]
    data["95th"] = lines[-7].strip().split(" ")[-1]

    arr = file.split("_")
    data["pd"] = int(arr[2])
    data["kv"] = int(arr[4])
    data["db"] = int(arr[6])
    data["round"] = int(arr[-1].split(".")[0])

    # print(data)
    return data
    # dump_data(data)
    # print(file)


def to_csv(data, to_csv):
    f = open(to_csv, 'w')
    for pd in data:
        for kv in data[pd]:
            for db in data[pd][kv]:
                # print("%2d %2d %2d   %5d %5d %5d" % (pd, kv, db, data[pd][kv][db]["tps"], data[pd][kv][db]["avg"], data[pd][kv][db]["95th"]))
                f.write("%2d, %2d, %2d,   %5d, %5d, %5d\n" % (pd, kv, db, data[pd][kv][db]["tps"], data[pd][kv][db]["avg"], data[pd][kv][db]["95th"]))

if __name__=="__main__":
   main()


