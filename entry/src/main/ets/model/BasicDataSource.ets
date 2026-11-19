/*
 * U4.1 IDataSource 基类（设计书 §5.5）：官方开发指南 BasicDataSource 示例同构 ArkTS 化。
 * 职责切分（基类持监听器+通知面、子类持数据——设计书 §5.5 拍板形态）：
 *   本类持 DataChangeListener 数组与四通知方法；totalCount/getData 由子类覆写。
 * 渲染纪律（设计书 §3.5，决策 11）：结构变更必走 notifyDataAdd/Delete/Reloaded（禁直改 visible
 * 不通知）；字段级刷新靠 @Observed（禁 emit notifyDataChange 双通道——本类保留该方法仅为
 * 接口面完整，DownloadListDataSource 零调用）。
 * IDataSource/DataChangeListener 为 ArkUI 全局环境类型（lazy_for_each.d.ts declare interface，
 * 零 import）；IDataSource.getData 返回 any——子类 T|undefined 返回值兼容。
 * ArkTS 合规：泛型类显式类型参数；遍历监听器用 indexed for（禁 for..in）；
 * 显式返回类型；无对象字面量。
 */

export class BasicDataSource<T> implements IDataSource {
  private listeners: DataChangeListener[] = [];

  /** 子类覆写（基类零数据持面） */
  totalCount(): number {
    return 0;
  }

  /** 子类覆写（基类零数据持面）；getData 内零排序/过滤/格式化耗时操作（devecocli docs 实测告诫） */
  getData(index: number): T | undefined {
    return undefined;
  }

  registerDataChangeListener(listener: DataChangeListener): void {
    if (this.listeners.indexOf(listener) === -1) {
      this.listeners.push(listener);
    }
  }

  unregisterDataChangeListener(listener: DataChangeListener): void {
    const pos: number = this.listeners.indexOf(listener);
    if (pos >= 0) {
      this.listeners.splice(pos, 1);
    }
  }

  /** 结构变更：新增项（调用方在数组 splice 后同步调用——通知与数组状态同栈，无撕裂窗口） */
  notifyDataAdd(index: number): void {
    for (let i = 0; i < this.listeners.length; i++) {
      this.listeners[i].onDataAdd(index);
    }
  }

  /** 结构变更：删除项 */
  notifyDataDelete(index: number): void {
    for (let i = 0; i < this.listeners.length; i++) {
      this.listeners[i].onDataDelete(index);
    }
  }

  /** 重算投影（过滤/排序/初始化）：整体重建视图后的整体刷新 */
  notifyDataReloaded(): void {
    for (let i = 0; i < this.listeners.length; i++) {
      this.listeners[i].onDataReloaded();
    }
  }

  /** 单项内容变更（U4.1 数据源零调用——字段级刷新走 @Observed，双通道重复刷新禁用） */
  notifyDataChange(index: number): void {
    for (let i = 0; i < this.listeners.length; i++) {
      this.listeners[i].onDataChange(index);
    }
  }
}
